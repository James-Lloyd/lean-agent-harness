#!/usr/bin/env bash
# fleet.sh — the fleet runner (bash mirror of fleet.ps1): opt-in parallel execution of INDEPENDENT
# tasks across git worktrees, with a serialized merge queue. "Parallel generation, serialized
# integration."
#
# Picks up to parallel.maxWorkers tasks from state/tasks.json that are file-ownership-partitioned
# (non-empty, non-overlapping `files` lists — lib/fleet.sh), snapshots HEAD as the batch base, builds
# each task with a headless `claude` worker in its own worktree/branch (fleet/<runId>/<taskId>), then
# integrates SERIALLY: squash-merge each branch onto the advancing tree, re-run the FULL project gate
# on the combined state, commit on green, park on conflict/red/tamper. Parked branches are kept for a
# human; merged ones are cleaned up. Workers never commit and never touch state/ — the runner records.
#
# Deliberately NOT the default way to work: coding has fewer truly parallelizable tasks than it
# seems, and each worker costs real tokens. Use it for a batch of genuinely independent items.
#
# Usage: bash harness/fleet.sh [--max N] [--dry-run]
# Requires: bash, git, jq, and the `claude` CLI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # engine dir (this script + lib/)
# PROJECT root (config, runtime, git, tasks.json) is DISTINCT from the engine dir once the engine ships
# from an installed plugin. Peek "$@" for --project-root before the main parser; else git top-level;
# else the current dir. In the in-repo layout these coincide, so paths are unchanged.
PROJECT_ROOT=""
_pr_prev=""
for _pr_arg in "$@"; do
  [ "$_pr_prev" = "--project-root" ] && PROJECT_ROOT="$_pr_arg"
  case "$_pr_arg" in --project-root=*) PROJECT_ROOT="${_pr_arg#*=}";; esac
  _pr_prev="$_pr_arg"
done
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(pwd)"
fi
REPO_ROOT="$PROJECT_ROOT"
cd "$REPO_ROOT"
HARNESS_DIR="$PROJECT_ROOT/harness"   # per-project config + gitignored runtime (.runs, .worktrees)
CONFIG="$HARNESS_DIR/harness.config.json"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG. Run /harness-init first."; exit 1; }
command -v jq >/dev/null || { echo "jq is required for the bash fleet (brew/apt install jq)."; exit 1; }

source "$SCRIPT_DIR/lib/gate.sh"
source "$SCRIPT_DIR/lib/checkpoint.sh"
source "$SCRIPT_DIR/lib/budget.sh"
source "$SCRIPT_DIR/lib/fleet.sh"
source "$SCRIPT_DIR/lib/invoke-codex.sh"   # codex invocation (codex_available, invoke_codex)
source "$SCRIPT_DIR/lib/dispatch.sh"       # invoke_phase: primary->fallback dispatcher

cfg() { jq -r "$1" "$CONFIG"; }

MAX_WORKERS="$(cfg '.parallel.maxWorkers // 3')"
WORKER_TURNS="$(cfg '.parallel.workerMaxTurns // .autonomy.maxTurnsPerIteration // 40')"
WORKER_TIMEOUT="$(cfg '.parallel.workerTimeoutSeconds // 3600')"
IMPLEMENT_MODEL="$(phase_model "$CONFIG" implement)"
IMPLEMENT_FALLBACK="$(phase_fallback "$CONFIG" implement)"   # cross-vendor fallback (e.g. "codex"); "" = none — parity with the loop
CODEX_AUTH="$(cfg '.models.codex.auth // "chatgpt"')"
CODEX_MODEL="$(cfg '.models.codex.model // empty')"
CODEX_EFFORT="$(cfg '.models.codex.reasoningEffort // empty')"
CODEX_TIMEOUT="$(cfg '.models.codex.timeoutSeconds // 900')"
CLAUDE_CMD="${HARNESS_CLAUDE_CMD:-claude}"   # injectable for stub-driven queue tests (parity: fleet.ps1)
MODE="$(cfg '.autonomy.mode')"
SKIP_PERMS="$(cfg '.autonomy.skipPermissions')"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --max) MAX_WORKERS="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --project-root) shift 2;;    # already captured in the pre-scan above
    --project-root=*) shift;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

assert_clean_git_tree
MANIFEST="$REPO_ROOT/state/tasks.json"
[ -f "$MANIFEST" ] || { echo "Missing state/tasks.json — run /plan first."; exit 1; }

# No mapfile: stock macOS ships bash 3.2 (mapfile is bash 4+), and README targets the .sh mirror there.
BATCH=()
while IFS= read -r _id; do
  if [ -n "$_id" ]; then BATCH+=("$_id"); fi
done < <(fleet_select_tasks "$MANIFEST" "$MAX_WORKERS")
if [ "${#BATCH[@]}" -eq 0 ] || [ -z "${BATCH[0]:-}" ]; then
  echo "No fleet-eligible tasks. Eligible = status todo/planned AND a non-empty 'files' ownership"
  echo "list in state/tasks.json that doesn't overlap another picked task. /plan declares ownership."
  exit 0
fi

RUN_ID="$(loop_run_id "$HARNESS_DIR/.runs")"
RUN_DIR="$HARNESS_DIR/.runs/$RUN_ID"
mkdir -p "$RUN_DIR"
FLEDGER="$RUN_DIR/fleet-ledger.jsonl"
fledger() { printf '%s\n' "$1" >> "$FLEDGER"; }

BASE_REF="$(git rev-parse HEAD)"
WT_ROOT="$HARNESS_DIR/.worktrees"
mkdir -p "$WT_ROOT"

echo "🚁 Fleet $RUN_ID | ${#BATCH[@]} worker(s) (max $MAX_WORKERS) | base ${BASE_REF:0:8} | model=${IMPLEMENT_MODEL:-inherit}"

task_field() {  # $1 id  $2 jq expr relative to the task object
  jq -r --arg id "$1" ".tasks[] | select(.id == \$id) | $2" "$MANIFEST"
}

worker_prompt() {  # $1 task id -> stdout
  local id="$1" desc steps acc comp files
  desc="$(task_field "$id" '.description')"
  steps="$(task_field "$id" '(.steps // []) | map("  - " + .) | join("\n")')"
  acc="$(task_field "$id" '.acceptance')"
  comp="$(task_field "$id" '.component')"
  files="$(task_field "$id" '(.files // []) | map("  - " + .) | join("\n")')"
  cat <<EOF
You are ONE worker in a parallel fleet. Other agents are building other tasks in sibling worktrees
right now. Implement exactly ONE task, fully, in THIS worktree.

TASK $id (component: $comp): $desc
Steps:
$steps
Acceptance: $acc

FILE OWNERSHIP — you may create/modify files ONLY under:
$files
Everything else belongs to another agent. Touching a file outside your ownership causes a merge
conflict that voids your work. If the task genuinely requires an unowned file, STOP and write why to
FLEET_NOTES.md in the repo root instead.

Rules:
1. Study first: CLAUDE.md, the relevant specs/, AGENT_NOTES.md. Search before assuming.
2. Full implementation — no placeholders, no stubs. Never weaken or delete a test. specs/ is locked.
3. Before finishing, run your component's gate commands (harness/harness.config.json -> components):
   format -> lint -> typecheck -> build -> test. Leave the gate green in this worktree.
4. Do NOT run git commit. Do NOT edit state/ files, AGENT_NOTES.md, harness/, or .claude/ — the fleet
   runner records results after your branch merges (parallel edits to shared files guarantee
   conflicts, and the merge queue rejects policy-file changes outright).
5. If blocked or the task is ambiguous, write the question to FLEET_NOTES.md and stop — don't guess.
EOF
}

# --- spawn workers ----------------------------------------------------------------
declare -a IDS=() BRANCHES=() PATHS=() PIDS=() LOGS=()
for id in "${BATCH[@]}"; do
  [ -n "$id" ] || continue
  branch="fleet/$RUN_ID/$id"
  wt="$WT_ROOT/$RUN_ID-$id"
  git worktree add -b "$branch" "$wt" "$BASE_REF" >/dev/null
  log="$RUN_DIR/fleet-$id.log"
  IDS+=("$id"); BRANCHES+=("$branch"); PATHS+=("$wt"); LOGS+=("$log")
  echo "   - $id: $(task_field "$id" '.description')  [owns: $(task_field "$id" '(.files // []) | join(", ")')]"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would run in $wt : claude -p --max-turns $WORKER_TURNS${IMPLEMENT_MODEL:+ --model $IMPLEMENT_MODEL}${IMPLEMENT_FALLBACK:+ (fallback: $IMPLEMENT_FALLBACK)}"
    PIDS+=("0")
    continue
  fi
  prompt="$(worker_prompt "$id")"
  (
    # set +e: the subshell inherits errexit, which would kill it on a non-zero worker exit BEFORE
    # `echo $?` runs — the exit file must be written for every outcome (ratchet).
    set +e
    cd "$wt" || { echo 1 > "$RUN_DIR/fleet-$id.exit"; exit 1; }
    export HARNESS_LOCK_SPECS=1
    # Route the worker build through the SAME dispatcher the loop uses (invoke_phase, workspace-write): the
    # primary runs, and ONLY on codex-unavailability or a usage-limit failure does it retry on the fallback,
    # resetting to the batch base ($BASE_REF) first. cwd is $wt (cd above), so the write-phase reset runs
    # inside the worktree — parity with the loop. Called directly (never in $(...)): a subshell would drop
    # invoke_phase's globals, and its stdout is already tee'd to $log, so redirect it away. The extra-args
    # array carries only the conditional flags (invoke_phase builds -p/--max-turns and guards the empty case).
    INVOKE_PHASE_CLAUDE_ARGS=()
    if [ "$MODE" = "auto" ] && [ "$SKIP_PERMS" = "true" ]; then INVOKE_PHASE_CLAUDE_ARGS+=(--dangerously-skip-permissions); fi
    invoke_phase workspace-write "$prompt" "$wt" "$log" "$IMPLEMENT_MODEL" "$IMPLEMENT_FALLBACK" "$BASE_REF" "$WORKER_TURNS" "$CODEX_AUTH" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_TIMEOUT" "$CLAUDE_CMD" >/dev/null 2>&1
    echo $? > "$RUN_DIR/fleet-$id.exit"
  ) &
  PIDS+=("$!")
  echo "  ▶ worker $id started in $wt"
done

if [ "$DRY_RUN" -eq 1 ]; then
  for i in "${!IDS[@]}"; do
    git worktree remove --force "${PATHS[$i]}" >/dev/null 2>&1 || true
    git branch -D "${BRANCHES[$i]}" >/dev/null 2>&1 || true
  done
  echo "[dry-run] cleaned up worktrees. No model invoked."
  exit 0
fi

# Watchdog: give the batch WORKER_TIMEOUT seconds total, then kill stragglers (their entry parks).
deadline=$((SECONDS + WORKER_TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  alive=0
  for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ "$alive" -eq 0 ] && break
  sleep 5
done
for p in "${PIDS[@]}"; do
  if kill -0 "$p" 2>/dev/null; then pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; fi
done
wait 2>/dev/null || true

# --- serialized merge queue --------------------------------------------------------
PARKED=""
park() {  # $1 id  $2 branch  $3 wt  $4 log  $5 why
  echo "  🅿 parked $1: $5 (branch $2 kept for inspection)"
  fledger "{\"task\":\"$1\",\"result\":\"parked\",\"why\":\"$5\",\"branch\":\"$2\"}"
  PARKED="${PARKED}- $1: $5 — branch $2, worktree $3, log $4
"
}

MERGED=0; PARKED_N=0
for i in "${!IDS[@]}"; do
  id="${IDS[$i]}"; branch="${BRANCHES[$i]}"; wt="${PATHS[$i]}"; log="${LOGS[$i]}"
  echo ""
  echo "── merge queue: $id ──"
  # Surface the worker's escalation channel whatever happens next (parked workers need it most).
  if [ -f "$wt/FLEET_NOTES.md" ]; then
    { printf '\n## Fleet %s — notes from worker %s\n' "$RUN_ID" "$id"; cat "$wt/FLEET_NOTES.md"; } >> "$REPO_ROOT/state/handoff.md"
  fi
  exit_file="$RUN_DIR/fleet-$id.exit"
  if [ ! -f "$exit_file" ]; then
    park "$id" "$branch" "$wt" "$log" "worker did not finish within ${WORKER_TIMEOUT}s"; PARKED_N=$((PARKED_N+1)); continue
  fi
  if [ "$(cat "$exit_file")" != "0" ]; then
    park "$id" "$branch" "$wt" "$log" "worker claude exited $(cat "$exit_file")"; PARKED_N=$((PARKED_N+1)); continue
  fi
  git -C "$wt" add -A
  staged="$(git -C "$wt" diff --cached --name-only)"
  if [ -z "$staged" ]; then
    park "$id" "$branch" "$wt" "$log" "worker produced no changes"; PARKED_N=$((PARKED_N+1)); continue
  fi
  # Policy tamper guard — must cover everything the worker prompt promises is rejected: specs, the
  # harness engine + config, ALL shared state (a worker marking other tasks done in tasks.json would
  # otherwise merge and be persisted by the runner's own record step), the prompt, and the notes file.
  if printf '%s\n' "$staged" | grep -qE '^(specs/|\.claude/|harness/|state/|PROMPT\.md$|AGENT_NOTES\.md$)'; then
    park "$id" "$branch" "$wt" "$log" "touched protected path(s)"; PARKED_N=$((PARKED_N+1)); continue
  fi
  # A silent commit failure turns every downstream record fail-open — check it or park (ratchet).
  if ! git -C "$wt" commit -q -m "fleet($id): worker build"; then
    park "$id" "$branch" "$wt" "$log" "worker-worktree commit failed (identity/hooks?)"; PARKED_N=$((PARKED_N+1)); continue
  fi
  # Squash-merge onto the CURRENT tree (which advances as earlier entries land) and re-run the FULL
  # gate on the combined state — locally-green is not queue-green.
  pre_merge="$(git rev-parse HEAD)"
  if ! git merge --squash "$branch" >/dev/null 2>&1; then
    git reset --hard "$pre_merge" >/dev/null; git clean -fd >/dev/null
    park "$id" "$branch" "$wt" "$log" "merge conflict with earlier queue entries — rebase/rerun after the batch"; PARKED_N=$((PARKED_N+1)); continue
  fi
  echo "  🔬 gate on combined state..."
  if ! run_gate "$CONFIG"; then
    git reset --hard "$pre_merge" >/dev/null; git clean -fd >/dev/null
    park "$id" "$branch" "$wt" "$log" "gate red on the combined state ($GATE_FAILED_STEP)"; PARKED_N=$((PARKED_N+1)); continue
  fi
  # Stage gate side effects too (a format step may have rewritten files — same reason the loop's
  # commit_iteration does add -A after the gate), then commit CHECKED: an empty squash or a hook
  # failure must park, not silently "merge" and mis-record.
  git add -A
  if ! git commit -q -m "fleet($id): $(task_field "$id" '.description')

Automated by harness/fleet ($RUN_ID). Gate green on combined state.
Co-Authored-By: Claude <noreply@anthropic.com>"; then
    git reset --hard "$pre_merge" >/dev/null; git clean -fd >/dev/null
    park "$id" "$branch" "$wt" "$log" "merge commit failed (empty squash or commit hook/identity)"; PARKED_N=$((PARKED_N+1)); continue
  fi
  echo "  ✔ merged + committed $id"
  fledger "{\"task\":\"$id\",\"result\":\"merged\",\"commit\":\"$(git rev-parse HEAD)\"}"
  MERGED=$((MERGED+1))
  # Record: advance the manifest (runner-owned; workers must not touch state/).
  tmp="$(mktemp)"
  jq --arg id "$id" --arg ev "harness/.runs/$RUN_ID/fleet-$id.log" \
     '(.tasks[] | select(.id == $id)) |= (.status = "validated" | .passes = true | .evidence = $ev)' \
     "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
  printf -- "- %s fleet %s: merged %s (gate green on combined state)\n" "$(date +%Y-%m-%d)" "$RUN_ID" "$id" >> "$REPO_ROOT/state/PROGRESS.md"
  git add state/tasks.json state/PROGRESS.md
  if ! git commit -q --amend --no-edit; then
    # Amend failed: the merge commit stands, but the state record isn't in it. Leaving the files merely
    # STAGED is unsafe — a LATER queue entry's merge-conflict/gate-red `reset --hard` (+ `clean -fd`) would
    # silently discard them while the ledger already says 'merged'. Persist the intended record to the run
    # dir (under harness/.runs — gitignored, so BOTH reset --hard and clean -fd skip it), restore the tracked
    # files so nothing is left staged for a later reset to eat, and ledger it so the morning routine can
    # reconcile pending-record-* against the 'merged' lines.
    pend_rel="harness/.runs/$RUN_ID/pending-record-$id"
    pend="$RUN_DIR/pending-record-$id"
    mkdir -p "$pend"
    cp "$REPO_ROOT/state/tasks.json"  "$pend/tasks.json"
    cp "$REPO_ROOT/state/PROGRESS.md" "$pend/PROGRESS.md"
    # || true: this is the graceful-degradation branch — under `set -e` a nonzero checkout (e.g. a state
    # file not yet in HEAD on a first-ever run) must NOT abort the whole queue. Parity with the ps1 twin,
    # whose `_Git` swallows the exit code. The pending copy is already written, so a failed restore is safe.
    git checkout HEAD -- state/tasks.json state/PROGRESS.md >/dev/null 2>&1 || true
    fledger "{\"task\":\"$id\",\"result\":\"record-deferred\",\"pending\":\"$pend_rel\"}"
    echo "  ! record amend failed — merge commit stands; pending record saved to $pend_rel (reconcile by hand)"
  fi
  # Cleanup only what merged; parked branches/worktrees stay for a human.
  git worktree remove --force "$wt" >/dev/null 2>&1 || true
  git branch -D "$branch" >/dev/null 2>&1 || true
done

# Parked tasks stop a human, not silently: surface them in the handoff.
if [ "$PARKED_N" -gt 0 ]; then
  printf '\n## Needs human decision — fleet %s parked %s task(s)\n%s' "$RUN_ID" "$PARKED_N" "$PARKED" >> "$REPO_ROOT/state/handoff.md"
fi

echo ""
echo "🏁 Fleet $RUN_ID done: $MERGED merged, $PARKED_N parked. Ledger: $FLEDGER"
echo "   Merged work sits at 'validated' — run /review (fresh context) before you trust it."
