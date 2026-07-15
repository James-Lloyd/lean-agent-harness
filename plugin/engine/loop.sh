#!/usr/bin/env bash
# The configurable autonomy loop (Ralph-style, with guardrails) — POSIX/bash mirror of loop.ps1.
# Stateless loop, stateful files: each iteration pipes PROMPT.md into a fresh headless `claude`,
# then runs the verification gate. Green => commit (+tag). Red (or gate error / config tampering) =>
# roll back. Bounded by maxIterations, a per-iteration --max-turns, and a best-effort tokenBudget.
# Supervised pauses at checkpoints; auto runs unattended.
#
# Usage: bash harness/loop.sh [--mode supervised|auto] [--max N] [--dry-run]
# Requires: bash, git, jq, and the `claude` CLI.  Do NOT edit the tree while it runs (rollback is hard).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # engine dir (this script + lib/)
# PROJECT root (config, runtime, git) is DISTINCT from the engine dir once the engine ships from an
# installed plugin. Peek "$@" for --project-root before the main parser (CONFIG is needed early); else
# git top-level; else the current dir. In the in-repo layout these coincide, so paths are unchanged.
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
HARNESS_DIR="$PROJECT_ROOT/harness"   # per-project config + gitignored runtime (.runs, etc.)
CONFIG="$HARNESS_DIR/harness.config.json"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG. Run /harness-init first."; exit 1; }
command -v jq >/dev/null || { echo "jq is required for the bash loop (brew/apt install jq)."; exit 1; }

# shellcheck source=lib/gate.sh
source "$SCRIPT_DIR/lib/gate.sh"
source "$SCRIPT_DIR/lib/checkpoint.sh"
source "$SCRIPT_DIR/lib/budget.sh"
source "$SCRIPT_DIR/lib/invoke-codex.sh"   # codex invocation (codex_available, invoke_codex) — dispatch.sh builds on it
source "$SCRIPT_DIR/lib/dispatch.sh"       # invoke_phase: primary->fallback dispatcher (after gate + invoke-codex)

cfg() { jq -r "$1" "$CONFIG"; }

MODE="$(cfg '.autonomy.mode')"
MAX_ITER="$(cfg '.autonomy.maxIterations')"
TOKEN_BUDGET="$(cfg '.autonomy.tokenBudget')"
SKIP_PERMS="$(cfg '.autonomy.skipPermissions')"
EVERY_N="$(cfg '.autonomy.checkpoints.everyNIterations')"; [ "$EVERY_N" = "null" ] && EVERY_N=0
MAX_TURNS="$(cfg '.autonomy.maxTurnsPerIteration')"; { [ "$MAX_TURNS" = "null" ] || [ -z "$MAX_TURNS" ]; } && MAX_TURNS=40
REVIEW_EVERY_N="$(cfg '.verification.reviewEveryNIterations')"; { [ "$REVIEW_EVERY_N" = "null" ] || [ -z "$REVIEW_EVERY_N" ]; } && REVIEW_EVERY_N=0
# Per-phase model routing (config.models, via phase_model in lib/gate.sh). "" = inherit the ambient
# CLI default (the pre-routing behavior, and what a /harness-prune-trimmed config degrades to).
IMPLEMENT_MODEL="$(phase_model "$CONFIG" implement)"
IMPLEMENT_FALLBACK="$(phase_fallback "$CONFIG" implement)"        # cross-vendor fallback (e.g. "codex"); "" = none
REVIEW_ROUTE="$(phase_model "$CONFIG" review)"                    # "codex" | claude alias/ID | ""
REVIEW_FALLBACK="$(phase_fallback "$CONFIG" review)"             # S1b: symmetric with the reviewFallback pseudo-phase
# Evaluator-at-review-point: when enabled it augments the SAME periodic review point, scoring the batch
# against the rubric. `cfg '... // default'` degrades a trimmed config to defaults instead of erroring.
EVAL_ENABLED="$(cfg '.verification.evaluator.enabled // false')"
EVAL_ROUTE="$(phase_model "$CONFIG" evaluate)"                    # "fable" | codex | claude alias/ID | ""
EVAL_FALLBACK="$(phase_fallback "$CONFIG" evaluate)"
EVAL_RUBRIC="$(cfg '.verification.evaluator.rubric // "docs/principles/evaluator-rubric.md"')"
EVAL_FAILBELOW="$(cfg '.verification.evaluator.failBelow // 7')"
CODEX_AUTH="$(cfg '.models.codex.auth // "chatgpt"')"
CODEX_MODEL="$(cfg '.models.codex.model // empty')"
CODEX_EFFORT="$(cfg '.models.codex.reasoningEffort // empty')"
CODEX_TIMEOUT="$(cfg '.models.codex.timeoutSeconds // 900')"
# Defaults for optional loop keys, so a trimmed config (e.g. after /harness-prune) degrades to the same
# defaults loop.ps1 uses instead of grepping a file literally named "null" / cat-ing it under set -e.
PLAN_FILE="$(cfg '.loop.planFile')";   { [ "$PLAN_FILE" = "null" ]   || [ -z "$PLAN_FILE" ]; }   && PLAN_FILE="state/fix_plan.md"
PROMPT_FILE="$(cfg '.loop.promptFile')"; { [ "$PROMPT_FILE" = "null" ] || [ -z "$PROMPT_FILE" ]; } && PROMPT_FILE="PROMPT.md"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --max)  MAX_ITER="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --project-root) shift 2;;    # already captured in the pre-scan above
    --project-root=*) shift;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

confirm_checkpoint() {  # $1 = label ; returns 0 to continue
  [ "$MODE" = "auto" ] && return 0
  printf '\n⏸  Checkpoint: %s\n   Continue? [y/N] ' "$1"
  read -r ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

open_item_count() {
  local plan n; plan="$PLAN_FILE"
  [ -f "$plan" ] || { echo 0; return; }
  # grep -c already prints 0 on no-match; `|| true` keeps set -e happy without a 2nd "0" line.
  n="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$plan" || true)"
  echo "${n:-0}"
}

any_e2e() {  # 0 if any component or root gate defines an e2e step
  [ "$(jq -r '[(.components[]?.gate.e2e), .gate.e2e] | map(select(. != null and . != "")) | length' "$CONFIG")" != "0" ]
}

# Periodic inferential judge: spawn a fresh-context reviewer over every commit since $1 (the last review
# watermark / run start). "doer != judge", wired into the unattended loop. Hardened: (1) reviewer runs
# READ-ONLY (--disallowedTools + a hard reset afterward) so a judge can't mutate what it judges; (2) it
# FAILS CLOSED — only an explicit VERDICT: SHIP continues; REJECT, truncation, crash, or empty all stop.
# Honest limitation: DIFF-ONLY — not granted tools to run the app, so it can't gather fresh e2e evidence.
# Returns 0 to continue; 1 to stop the loop for a human.
periodic_review() {  # $1 base  $2 run_dir  $3 iter
  local base="$1" run_dir="$2" iter="$3" head out reviewlog stamp prompt reason rc
  head="$(git rev-parse HEAD)"
  if [ "$base" = "$head" ]; then echo "  (periodic review: no new commits since last review)"; return 0; fi
  echo "🧑‍⚖️  Periodic fresh-context review of commits ${base:0:8}..${head:0:8}..."
  reviewlog="$run_dir/review-after-$iter.log"
  read -r -d '' prompt <<EOF || true
You are a FRESH-CONTEXT REVIEWER (the harness 'reviewer' role — see .claude/agents/reviewer.md). You
have NO memory of how this code was written; judge only the artifact. You are READ-ONLY — do not edit,
write, or commit anything.

1. Inspect the batch:  git log --oneline $base..HEAD   and   git diff $base..HEAD
2. Judge it against specs/ (acceptance criteria) and docs/principles/ (golden principles): correctness
   vs spec, evidence quality, guardrails (no weakened/deleted tests, no edited specs, no destructive
   ops/secrets), architectural drift, needless complexity.
3. List findings as  file:line — problem — concrete fix. Report ONLY findings that affect correctness
   vs the spec, evidence integrity, or the guardrails. Do NOT manufacture style/architecture
   suggestions to justify the review — a reviewer told to find problems always will, and invented
   findings cause over-engineering churn. "No findings" is a valid outcome: SHIP it.

Finish with EXACTLY ONE final line and nothing after it:
VERDICT: SHIP     (the batch is sound)
VERDICT: REJECT   (anything is wrong — default to REJECT when unsure)
EOF
  # Route the judge through the cross-vendor dispatcher (invoke_phase, READ-ONLY): primary = the resolved
  # review model (e.g. "codex" => codex read-only sandbox; a claude alias => that reviewer; "" => inherit),
  # fallback = the S1b-symmetric claude reviewer model. Net effect: the review path now ALSO falls back to
  # the claude reviewer on a codex USAGE-LIMIT (not just pre-invocation unavailability), while preserving
  # the unavailable->claude path. Disallowed tools as SEPARATE args (a space-joined string is one
  # never-matching pattern); Bash stays enabled — the reviewer needs `git log`/`git diff`; the hard reset
  # below undoes any mutation. reset_ref="" and max_turns=20; read-only => no write-phase reset inside.
  INVOKE_PHASE_CLAUDE_ARGS=(--disallowedTools Edit Write MultiEdit NotebookEdit)
  # invoke_phase must run in THIS shell (not $(...)) so INVOKE_PHASE_* propagate; capture its stdout (the
  # verdict text) via a redirect to a temp file, which does NOT spawn a subshell.
  local review_out; review_out="$(mktemp)"
  if invoke_phase read-only "$prompt" "$REPO_ROOT" "$reviewlog" "$REVIEW_ROUTE" "$REVIEW_FALLBACK" "" 20 "$CODEX_AUTH" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_TIMEOUT" > "$review_out"; then rc=0; else rc=$?; fi
  out="$(cat "$review_out")"; rm -f "$review_out"
  local review_path="${INVOKE_PHASE_PATH:-claude}"
  # A judge must not mutate the artifact: restore the tree to exactly the reviewed HEAD, no matter
  # what. (Codex ran in a read-only sandbox, but belt + braces — identical to the claude path.)
  git reset --hard "$head" >/dev/null 2>&1 || true; git clean -fd >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ]; then
    echo "  ! review invocation failed ($review_path) — failing closed (stopping for human)."
    ledger "{\"iter\":$iter,\"result\":\"review\",\"path\":\"$review_path\",\"verdict\":\"ERROR\"}"
    _reject_handoff "review could not run ($review_path)" "$base" "$head" "$iter" "$reviewlog"; return 1
  fi
  # Fail-closed verdict parse: only the LAST line starting with VERDICT: counts (review_verdict in
  # lib/gate.sh). A preamble like "I cannot give VERDICT: SHIP" must never pass the batch.
  local v; v="$(printf '%s\n' "$out" | review_verdict)"
  ledger "{\"iter\":$iter,\"result\":\"review\",\"path\":\"$review_path\",\"verdict\":\"$v\"}"
  case "$v" in
    SHIP)
      echo "  🟢 Periodic review: SHIP."
      # NB: the harness-reviewed watermark tag is advanced by the CALLER, only after BOTH the reviewer AND
      # (when enabled) the evaluator pass — else a reviewer-SHIP-then-evaluator-FAIL batch would be tagged
      # "reviewed" while the loop stops like a REJECT, hiding rejected work from a later /review.
      return 0;;
    REJECT) reason="REJECT";;
    *) reason="no clear SHIP verdict (fail-closed)";;
  esac
  echo "  🔴 Periodic review: $reason. Stopping for human attention."
  _reject_handoff "$reason" "$base" "$head" "$iter" "$reviewlog"; return 1
}

_reject_handoff() {  # $1 reason  $2 base  $3 head  $4 iter  $5 log
  printf '\n## Needs human decision — periodic review: %s (%s..%s, iter %s)\nThe fresh-context reviewer did not return SHIP. Findings: %s. Inspect before continuing the loop.\n' \
    "$1" "${2:0:8}" "${3:0:8}" "$4" "$5" >> "$REPO_ROOT/state/handoff.md"
}

# Periodic EVALUATION at the review point (bash mirror of Invoke-PeriodicEvaluation). When
# verification.evaluator.enabled, AFTER the fresh-context reviewer returns SHIP the loop also scores the
# same base..HEAD batch against the rubric. READ-ONLY (--disallowedTools + a hard reset afterward) so the
# judge can't mutate what it judges, and FAILS CLOSED — only a clean PASS (verdict PASS AND every criterion
# >= failBelow via evaluator_verdict) continues; a FAIL, no clear verdict, a crash, or ANY sub-threshold
# N/10 stops the loop like a REJECT. Returns 0 to continue; 1 to stop the loop for a human.
periodic_evaluation() {  # $1 base  $2 run_dir  $3 iter
  local base="$1" run_dir="$2" iter="$3" head out evallog prompt reason rc v
  head="$(git rev-parse HEAD)"
  if [ "$base" = "$head" ]; then echo "  (periodic evaluation: no new commits since last review)"; return 0; fi
  echo "🧮  Periodic evaluator scoring commits ${base:0:8}..${head:0:8} against $EVAL_RUBRIC..."
  evallog="$run_dir/evaluate-after-$iter.log"
  read -r -d '' prompt <<EOF || true
You are a SKEPTICAL EVALUATOR (the harness 'evaluator' role — see .claude/agents/evaluator.md). You have
NO memory of how this code was written; judge only the artifact. You are READ-ONLY — do not edit, write,
or commit anything.

1. Read the scoring rubric at:  $EVAL_RUBRIC
2. Inspect the batch:  git log --oneline $base..HEAD   and   git diff $base..HEAD
3. Check the work against specs/ (acceptance criteria) and the captured end-to-end evidence under
   state/evidence/. Exercise that evidence READ-ONLY where you can (read logs/outputs; run only
   non-mutating commands). A guardrail breach (weakened/deleted tests, edited specs, destructive ops,
   secrets) caps the sprint regardless of other scores.
4. Score EVERY applicable criterion 0-10 with a one-line justification, applying the hard threshold
   failBelow=$EVAL_FAILBELOW: ANY criterion below $EVAL_FAILBELOW => the sprint FAILS.

Output EXACTLY the rubric's format — the per-criterion N/10 scores — and finish with EXACTLY ONE final
line and nothing after it:
VERDICT: PASS     (every applicable criterion scored >= $EVAL_FAILBELOW, no guardrail breach)
VERDICT: FAIL     (any criterion below $EVAL_FAILBELOW, any guardrail breach, or unsure)
EOF
  # Route through the cross-vendor dispatcher (invoke_phase, READ-ONLY) exactly like the reviewer; primary =
  # the resolved evaluate model, fallback = its claude fallback. Disallowed write tools as SEPARATE args;
  # Bash stays enabled (the judge needs git log/diff + read-only evidence commands). invoke_phase must run
  # in THIS shell so INVOKE_PHASE_* globals propagate; capture stdout via a redirect (no subshell).
  INVOKE_PHASE_CLAUDE_ARGS=(--disallowedTools Edit Write MultiEdit NotebookEdit)
  local eval_out; eval_out="$(mktemp)"
  if invoke_phase read-only "$prompt" "$REPO_ROOT" "$evallog" "$EVAL_ROUTE" "$EVAL_FALLBACK" "" 20 "$CODEX_AUTH" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_TIMEOUT" > "$eval_out"; then rc=0; else rc=$?; fi
  out="$(cat "$eval_out")"; rm -f "$eval_out"
  local eval_path="${INVOKE_PHASE_PATH:-claude}"
  # A judge must not mutate the artifact: restore the tree to exactly the evaluated HEAD, no matter what.
  git reset --hard "$head" >/dev/null 2>&1 || true; git clean -fd >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ]; then
    echo "  ! evaluator invocation failed ($eval_path) — failing closed (stopping for human)."
    ledger "{\"iter\":$iter,\"result\":\"evaluate\",\"path\":\"$eval_path\",\"verdict\":\"ERROR\"}"
    _reject_handoff "evaluator could not run ($eval_path)" "$base" "$head" "$iter" "$evallog"; return 1
  fi
  # Fail-closed parse + belt-and-braces threshold scan (evaluator_verdict in lib/gate.sh): any
  # sub-threshold N/10 overrides a PASS summary.
  v="$(printf '%s\n' "$out" | evaluator_verdict "$EVAL_FAILBELOW")"
  ledger "{\"iter\":$iter,\"result\":\"evaluate\",\"path\":\"$eval_path\",\"verdict\":\"$v\"}"
  case "$v" in
    PASS) echo "  🟢 Periodic evaluation: PASS."; return 0;;
    FAIL) reason="evaluator FAIL (below-threshold criterion)";;
    *)    reason="no clear PASS verdict (fail-closed)";;
  esac
  echo "  🔴 Periodic evaluation: $reason. Stopping for human attention."
  _reject_handoff "$reason" "$base" "$head" "$iter" "$evallog"; return 1
}

RUN_ID="$(loop_run_id "$HARNESS_DIR/.runs")"   # atomically claims <project>/harness/.runs/<runId>/ (mkdir-as-mutex)
RUN_DIR="$HARNESS_DIR/.runs/$RUN_ID"
mkdir -p "$RUN_DIR"
LEDGER="$RUN_DIR/ledger.jsonl"
# Per-run state files: two concurrent runs must not share a rollback ref or a budget tally.
set_checkpoint_file "$RUN_DIR/.checkpoint"
set_budget_file "$RUN_DIR/.budget.json"
reset_budget   # per-run cap, not a lifetime counter
ledger() { printf '%s\n' "$1" >> "$LEDGER"; }
config_hash() { git hash-object "$CONFIG"; }
CONFIG_HASH0="$(config_hash)"

assert_clean_git_tree
PROJ_TYPE="$(cfg '.project.type')"; [ "$PROJ_TYPE" = "null" ] && PROJ_TYPE="greenfield"
echo "🔧 Harness loop | type=$PROJ_TYPE | mode=$MODE | maxIter=$MAX_ITER | maxTurns=$MAX_TURNS | model=${IMPLEMENT_MODEL:-inherit} | budget=$TOKEN_BUDGET"

if [ "$MODE" = "auto" ] && [ "$(cfg '.verification.requireE2EEvidence')" = "true" ] && ! any_e2e; then
  echo "⚠️  auto mode + requireE2EEvidence, but no e2e gate step is configured. The loop will commit on"
  echo "    unit-green only. Add an e2e command to a component/root gate, or run /review periodically."
fi

# Honest guard (mirrors the e2e warning): the evaluator augments the periodic review point, which is gated
# on BOTH reviewEveryNIterations>0 AND loop.commitOnGreen — with either off it can never fire.
if [ "$EVAL_ENABLED" = "true" ] && { [ "$REVIEW_EVERY_N" -le 0 ] || [ "$(cfg '.loop.commitOnGreen')" != "true" ]; }; then
  if [ "$REVIEW_EVERY_N" -le 0 ]; then _eval_why="reviewEveryNIterations <= 0"; else _eval_why="loop.commitOnGreen is false"; fi
  echo "⚠️  verification.evaluator.enabled is true but $_eval_why — the evaluator augments the periodic"
  echo "    review point (needs reviewEveryNIterations>0 AND commitOnGreen), so it will never run."
fi

if [ "$PROJ_TYPE" = "brownfield" ]; then
  if [ "$(cfg '.project.baseline.established')" != "true" ]; then
    echo "⚠️  Brownfield project with NO established green baseline. Run /onboard first."
    confirm_checkpoint "Continue without an established baseline?" || exit 0
  fi
  if [ "$MODE" = "auto" ]; then
    echo "⚠️  AUTO mode on a BROWNFIELD codebase. The auto-loop is designed for greenfield; on existing"
    echo "    code it risks wide, subtle regressions. Supervised + small isolated tasks is recommended."
    confirm_checkpoint "Run full-auto on an existing codebase anyway?" || exit 0
  fi
fi
if [ "$MODE" = "auto" ] && [ "$SKIP_PERMS" = "true" ]; then
  echo "⚠️  AUTO + skipPermissions: model runs UNATTENDED with permission prompts disabled."
  echo "    The deny-list (incl. secrets) is VOID in this mode — run inside a sandbox/container."
  confirm_checkpoint "Proceed with unattended skip-permissions run?" || exit 0
else
  # Headless children can't answer permission prompts: any Bash command NOT in permissions.allow is
  # auto-denied, so if the gate commands aren't allowlisted the agent can't run PROMPT.md Phase 3 and
  # burns iterations editing blind. /harness-init appends them; remind here in case it didn't.
  echo "ℹ️  Headless runs auto-deny non-allowlisted commands. Ensure the gate commands (test/build/lint)"
  echo "    are in .claude/settings.json permissions.allow (/harness-init adds them)."
fi

# Sandbox guard: full-auto runs UNATTENDED. The destructive-command deny-list is defense-in-depth, not a
# sandbox, so honestly warn (not block — confirm_checkpoint is a no-op in auto by design) when auto runs
# outside a recognized isolation profile. is_sandboxed lives in lib/gate.sh (already sourced above).
if [ "$MODE" = "auto" ] && ! is_sandboxed; then
  echo ""
  echo "⚠️  AUTO mode but NOT in a recognized SANDBOX. This run is full-auto and UNATTENDED."
  echo "    Unattended auto should run inside the documented isolation profile (container/devcontainer or"
  echo "    WSL2-native FS), not directly on your host. The destructive-command deny-list is defense-in-"
  echo "    depth, NOT a sandbox — and --dangerously-skip-permissions voids it entirely."
  echo "    See docs/sandboxing.md. Mark a sandbox explicitly with:  export HARNESS_SANDBOX=1"
  echo ""
fi

# Lock specs/ for the run: the protect-specs PreToolUse hook (inherited by the headless claude child)
# blocks edits under specs/ while this is exported. The loop must never rewrite the contract.
export HARNESS_LOCK_SPECS=1

PROMPT="$(cat "$PROMPT_FILE")"
i=0
GREEN_COUNT=0
REVIEW_BASE="$(git rev-parse HEAD)"   # periodic-review watermark: commits after this are unreviewed
while [ "$i" -lt "$MAX_ITER" ]; do
  i=$((i+1))
  if [ "$(cfg '.loop.stopWhenPlanEmpty')" = "true" ] && [ "$(open_item_count)" -eq 0 ]; then
    echo "✅ fix_plan.md has no open items — stopping."; break
  fi
  if [ "$TOKEN_BUDGET" != "null" ] && budget_exceeded "$TOKEN_BUDGET"; then
    echo "💸 Token budget (estimate) exhausted — stopping."; break
  fi
  if [ "$EVERY_N" -gt 0 ] && [ $((i % EVERY_N)) -eq 0 ]; then
    confirm_checkpoint "Reached iteration $i" || break
  fi

  echo "──────── iteration $i / $MAX_ITER ────────"
  ITER_LOG="$RUN_DIR/iter-$i.log"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would pipe $PROMPT_FILE into: claude -p --max-turns $MAX_TURNS${IMPLEMENT_MODEL:+ --model $IMPLEMENT_MODEL} ; then run the gate."; break
  fi

  new_checkpoint "pre-iter-$i"
  # Invoke the implement phase through the cross-vendor dispatcher (invoke_phase). Prompt via STDIN (the
  # documented `cat file | claude -p` pattern; parity with loop.ps1). Do NOT add --bare: the loop DEPENDS
  # on hook/CLAUDE.md/skill discovery (CLI docs say --bare becomes the -p default later; pin/revisit then).
  # Extra claude args mirror today's conditions: skip-permissions under auto+skipPermissions, JSON when
  # metering. The dispatcher runs $IMPLEMENT_MODEL (primary) and, ONLY on codex-unavailability or a
  # usage-limit failure, $IMPLEMENT_FALLBACK — hard-resetting to this iteration's base ($BASE_REF) before
  # a write-phase fallback. A generic (non-usage) failure returns as failure: roll back + continue, as today.
  # invoke_phase must run in THIS shell (not a $(...) subshell) so its INVOKE_PHASE_* globals propagate;
  # its stdout (the buffered phase output, also tee'd to $ITER_LOG) streams to the console directly.
  INVOKE_PHASE_CLAUDE_ARGS=()
  if [ "$MODE" = "auto" ] && [ "$SKIP_PERMS" = "true" ]; then INVOKE_PHASE_CLAUDE_ARGS+=(--dangerously-skip-permissions); fi
  if [ "$(cfg '.autonomy.meterTokens')" = "true" ]; then INVOKE_PHASE_CLAUDE_ARGS+=(--output-format json); fi   # exact usage
  BASE_REF="$(git rev-parse HEAD)"   # clean tree here (new_checkpoint asserts it): the fallback reset target
  if invoke_phase workspace-write "$PROMPT" "$REPO_ROOT" "$ITER_LOG" "$IMPLEMENT_MODEL" "$IMPLEMENT_FALLBACK" "$BASE_REF" "$MAX_TURNS" "$CODEX_AUTH" "$CODEX_MODEL" "$CODEX_EFFORT" "$CODEX_TIMEOUT"; then impl_rc=0; else impl_rc=$?; fi
  echo   # newline after the buffered phase output
  if [ "$impl_rc" -ne 0 ]; then
    impl_uf=false; [ "${INVOKE_PHASE_USED_FALLBACK:-0}" = "1" ] && impl_uf=true
    echo "❌ implement phase failed (path=${INVOKE_PHASE_PATH:-} reason=${INVOKE_PHASE_REASON:-invoke-failed})"
    ledger "{\"iter\":$i,\"result\":\"invoke-error\",\"reason\":\"${INVOKE_PHASE_REASON:-invoke-failed}\",\"path\":\"${INVOKE_PHASE_PATH:-}\",\"usedFallback\":$impl_uf}"
    restore_checkpoint; continue
  fi
  update_budget_from_log "$ITER_LOG"

  if [ "$(config_hash)" != "$CONFIG_HASH0" ]; then
    echo "🛑 harness.config.json changed during the iteration (gate/policy tampering?). Rolling back and stopping."
    ledger "{\"iter\":$i,\"result\":\"config-tampered\"}"; restore_checkpoint; break
  fi

  echo "🔬 Running verification gate..."
  if run_gate "$CONFIG"; then
    echo "🟢 Gate green."
    [ "$(cfg '.loop.commitOnGreen')" = "true" ] && commit_iteration "$i"
    [ "$(cfg '.loop.tagOnGreen')" = "true" ]    && tag_iteration "$i" "$RUN_ID"
    clear_checkpoint
    green_uf=false; [ "${INVOKE_PHASE_USED_FALLBACK:-0}" = "1" ] && green_uf=true
    ledger "{\"iter\":$i,\"result\":\"green\",\"path\":\"${INVOKE_PHASE_PATH:-}\",\"usedFallback\":$green_uf}"
    GREEN_COUNT=$((GREEN_COUNT+1))
    # Inferential judge, wired in: every N green iterations a fresh-context reviewer audits the batch.
    if [ "$REVIEW_EVERY_N" -gt 0 ] && [ "$(cfg '.loop.commitOnGreen')" = "true" ] && [ $((GREEN_COUNT % REVIEW_EVERY_N)) -eq 0 ]; then
      if periodic_review "$REVIEW_BASE" "$RUN_DIR" "$i"; then review_ok=0; else review_ok=1; fi
      # The evaluator augments the SAME review point: when enabled, only after the reviewer SHIPs do we
      # also score the batch against the rubric. Advance the watermark only when BOTH pass; any
      # below-threshold criterion stops the loop like a REJECT (periodic_evaluation writes the handoff).
      if [ "$review_ok" -eq 0 ] && [ "$EVAL_ENABLED" = "true" ]; then
        if periodic_evaluation "$REVIEW_BASE" "$RUN_DIR" "$i"; then review_ok=0; else review_ok=1; fi
      fi
      if [ "$review_ok" -eq 0 ]; then
        REVIEW_BASE="$(git rev-parse HEAD)"   # advance the watermark past the reviewed batch
        git tag -f harness-reviewed "$REVIEW_BASE" >/dev/null 2>&1 || true   # both judges passed: mark reviewed for a later /review
      else
        ledger "{\"iter\":$i,\"result\":\"review-stop\"}"; break
      fi
    fi
  else
    echo "🔴 Gate red: $GATE_FAILED_STEP"
    red_uf=false; [ "${INVOKE_PHASE_USED_FALLBACK:-0}" = "1" ] && red_uf=true
    ledger "{\"iter\":$i,\"result\":\"red\",\"failedStep\":\"$GATE_FAILED_STEP\",\"path\":\"${INVOKE_PHASE_PATH:-}\",\"usedFallback\":$red_uf}"
    if [ "$(cfg '.loop.autoRollbackOnRed')" = "true" ]; then
      echo "↩  Rolling back to keep the tree green."; restore_checkpoint
    else
      echo "   autoRollbackOnRed=false — leaving tree for inspection. Stopping."; break
    fi
  fi
done

echo "🏁 Loop finished after $i iteration(s). Logs + ledger: $RUN_DIR"
echo "   Next: run /review for a fresh-context QA pass before you trust this."
