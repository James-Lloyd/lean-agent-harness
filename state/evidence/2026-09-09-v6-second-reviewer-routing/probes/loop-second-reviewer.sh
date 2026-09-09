#!/usr/bin/env bash
# Arm E — the LOOP's review point with BOTH judges: a (stubbed) Claude primary that SHIPs, then the
# REAL Codex CLI as `models.review.second`. This is the one path V6.1 turns on and the one path that
# had never been live-fired: PR #23 proved a codex PRIMARY reviewer, never `second_review`.
#
# What only this arm can show: the loop consults the second judge ONLY after the primary ships, both
# verdicts reach the ledger, the second judge's transcript lands on disk, and the tree is clean
# afterwards (a judge may not mutate what it judges).
#
# Scaffolding is lifted from probes/loop-review-codex.sh in the 2026-09-09 codex-invoke evidence dir,
# so the only difference from that arm is WHICH judge is real.
#
# COST: one real codex call. PROBE_SKIP_MODEL=1 skips the whole arm.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6-second-reviewer-routing/probes/loop-second-reviewer.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$OUT/loop-second-reviewer.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }

if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   arm E skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
command -v jq >/dev/null 2>&1 || { echo "REFUSING: jq not installed"; exit 2; }

export HARNESS_ENGINE="$ROOT/plugin/engine"
WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT

# The stub answers for BOTH Claude roles: the implementer and the PRIMARY reviewer. It must never be
# asked to play the second judge — if it is, the routing is broken and the arm fails loudly rather
# than quietly passing on a Claude "second opinion".
cat > "$WORK/stub-claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
model=""; prev=""
for a in "$@"; do [ "$prev" = "--model" ] && model="$a"; prev="$a"; done
case "$model" in
  impl-x)
    mkdir -p out && echo "built" > out/a.txt
    sed -i.bak 's/^- \[ \] build thing/- [x] build thing/' state/fix_plan.md && rm -f state/fix_plan.md.bak
    echo "implemented"; exit 0;;
  primary-judge)
    echo "No correctness or requirement gaps found."
    echo "VERDICT: SHIP"; exit 0;;
  *) echo "stub: unexpected model '$model' — the codex SECOND judge must NOT come through claude" >&2; exit 1;;
esac
STUB
chmod +x "$WORK/stub-claude"

T="$WORK/repo"; mkdir -p "$T"; cd "$T" || exit 1
git init -q -b main
git config core.autocrlf false
git config user.email loop-second@example.com
git config user.name "Loop Second Judge Probe"
cp -r "$ROOT/harness" .
rm -rf harness/.runs harness/.worktrees
mkdir -p state
cat > harness/harness.config.json <<'JSON'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": {
    "implement": { "model": "impl-x", "fallback": null },
    "review":    { "model": "primary-judge", "fallback": null, "second": { "model": "codex", "effort": "high" },
                   "codex": { "model": null, "reasoningEffort": "high" } },
    "codex":     { "model": null, "reasoningEffort": "medium", "auth": "chatgpt", "timeoutSeconds": 300 }
  },
  "autonomy": { "mode": "auto", "maxIterations": 1, "maxTurnsPerIteration": 10, "tokenBudget": null, "meterTokens": false, "skipPermissions": false,
                "checkpoints": { "planApproval": false, "beforeRiskyOps": false, "everyNIterations": 0 } },
  "loop": { "promptFile": "PROMPT.md", "planFile": "state/fix_plan.md", "progressFile": "state/PROGRESS.md",
            "oneItemPerIteration": true, "autoRollbackOnRed": true, "commitOnGreen": true, "tagOnGreen": false, "stopWhenPlanEmpty": true },
  "verification": { "requireE2EEvidence": false, "reviewEveryNIterations": 1, "evaluator": { "enabled": false } },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
JSON
printf '## Tasks\n- [ ] build thing\n' > state/fix_plan.md
printf '{ "version": 2, "tasks": [] }\n' > state/tasks.json
echo "- init" > state/PROGRESS.md
echo "do the top task" > PROMPT.md
printf 'harness/.runs/\nharness/.worktrees/\nstate/handoff.md\n' > .gitignore
git add -A && git commit -q -m "init"

echo "### arm E: loop.sh --mode auto — stubbed Claude primary SHIPs, real Codex second judges the same batch"
HARNESS_CLAUDE_CMD="$WORK/stub-claude" bash harness/loop.sh --mode auto --max 1 > "$WORK/loop.out" 2>&1
loop_rc=$?
cp "$WORK/loop.out" "$OUT/arm-e-loop.out" 2>/dev/null
LEDGER=harness/.runs/run-001/ledger.jsonl
echo "    loop exit=$loop_rc"
echo "    ledger:"; sed 's/^/      /' "$LEDGER" 2>/dev/null

pline="$(grep '"result":"review"' "$LEDGER" 2>/dev/null | tail -1)"
sline="$(grep '"result":"review-second"' "$LEDGER" 2>/dev/null | tail -1)"

if [ -z "$pline" ]; then bad "no primary review line in the ledger"; else
  pv="$(printf '%s' "$pline" | jq -r '.verdict // ""')"
  pp="$(printf '%s' "$pline" | jq -r '.path // ""')"
  [ "$pv" = "SHIP" ] && ok "primary (Claude) verdict SHIP — the precondition for consulting the second" || bad "primary verdict='$pv'"
  [ "$pp" = "claude" ] && ok "primary went down the claude path" || bad "primary path='$pp', expected claude"
fi

if [ -z "$sline" ]; then bad "NO review-second line — the second judge never ran (this is the whole point of the arm)"; else
  sp="$(printf '%s' "$sline" | jq -r '.path // ""')"
  sv="$(printf '%s' "$sline" | jq -r '.verdict // ""')"
  sm="$(printf '%s' "$sline" | jq -r '.model // ""')"
  [ "$sp" = "codex" ]  && ok "second judge went down the REAL codex path" || bad "second path='$sp', expected codex"
  [ "$sm" = "codex" ]  && ok "ledger records the routed second model" || bad "second model='$sm'"
  case "$sv" in
    SHIP)   ok "codex second returned a parsed verdict: SHIP (both judges shipped)";;
    REJECT) ok "codex second returned a parsed verdict: REJECT — SHIP requires BOTH, so the loop correctly stops for a human";;
    ERROR)  bad "second verdict=ERROR — the codex invocation failed; see the transcript";;
    *)      bad "second verdict='$sv' — nothing parsed (fails closed, but the contract is broken)";;
  esac
fi

# Order matters: the second judge is consulted only AFTER the primary ships.
if [ -n "$pline" ] && [ -n "$sline" ]; then
  pno="$(grep -n '"result":"review"' "$LEDGER" | tail -1 | cut -d: -f1)"
  sno="$(grep -n '"result":"review-second"' "$LEDGER" | tail -1 | cut -d: -f1)"
  [ "$pno" -lt "$sno" ] && ok "ledger order is primary -> second (line $pno before $sno)" || bad "second review recorded before the primary (lines $sno, $pno)"
fi

t="$(ls harness/.runs/run-001/review-second-after-*.log 2>/dev/null | head -1)"
if [ -n "$t" ] && [ -s "$t" ]; then
  ok "second reviewer transcript written ($(basename "$t"), $(wc -l < "$t") lines)"
  cp "$t" "$OUT/arm-e-second-transcript.log"
  # The transcript is the CLI's own report of its effective state — assert on it, not on the argv.
  grep -qE '^approval: never' "$t" && ok "second judge ran with approval: never (its own header says so)" || bad "the second judge's header does not report 'approval: never'"
  grep -qE '^sandbox: read-only' "$t" && ok "second judge ran read-only (its own header says so)" || bad "the second judge's header does not report 'sandbox: read-only'"
  # THE DOC CLAIM THIS SLICE FIXED, MEASURED AT THE CLI. The fixture's GLOBAL models.codex says
  # medium; review.codex says high. A header reading `high` proves the per-phase block is read for a
  # codex SECOND even though review.model and review.fallback are both Claude — the case four
  # surfaces described as an unread key until 2026-09-09.
  grep -qE '^reasoning effort: high' "$t" \
    && ok "review.codex.reasoningEffort (high) beat the global block (medium) for the SECOND judge" \
    || bad "second judge's depth is $(grep -m1 -E '^reasoning effort:' "$t"), expected high from review.codex"
else
  bad "no second-reviewer transcript on disk"
fi

[ -z "$(git status --porcelain)" ] && ok "tree clean after both judges ran" || bad "tree dirty after review: $(git status --porcelain | head -3)"

echo
echo "RESULT: arm E $([ "$rc" = 0 ] && echo GREEN || echo RED)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/arm-e-loop.out" "$OUT/arm-e-second-transcript.log" >/dev/null 2>&1
# VERIFY THE SCRUB, never assume it. arm-e-second-transcript.log CERTAINLY contains a real home path
# (codex prints `workdir:` in its header), so a missing node or a throwing scrub.mjs would land a
# username in state/evidence/ under a GREEN result. Written to stderr because stdout is closed above.
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/arm-e-loop.out" "$OUT/arm-e-second-transcript.log"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit "$rc"
