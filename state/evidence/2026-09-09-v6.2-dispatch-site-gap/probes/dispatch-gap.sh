#!/usr/bin/env bash
# V6.2 — MEASURE the gap that /harness-doctor 10(i) now grades, rather than asserting it.
#
# Claim under test: `"codex"` is legal syntax on every phase, but `plan`, `explore` and `docs` have no
# headless dispatch site, so a loop run silently ignores the value. The doctor table is only as good as
# this measurement, so take it from a REAL loop run over a config that routes all three to codex.
#
# COST: none. The implementer is stubbed and no phase this probe exercises reaches a real model —
# which is itself the finding: if `docs: "codex"` were honoured anywhere, this run would have tried.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.2-dispatch-site-gap/probes/dispatch-gap.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$OUT/dispatch-gap.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }

command -v jq >/dev/null 2>&1 || { echo "REFUSING: jq not installed"; exit 2; }
export HARNESS_ENGINE="$ROOT/plugin/engine"
WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT

# A stub that stands in for BOTH vendors' CLIs. If any phase this config routes to codex were actually
# dispatched, the run would call `codex` — which does not exist on this PATH-stub, so the stub records
# the attempt. Nothing here can reach a paid model.
cat > "$WORK/stub-claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
model=""; prev=""
for a in "$@"; do [ "$prev" = "--model" ] && model="$a"; prev="$a"; done
echo "$model" >> "$STUB_CALLS"
case "$model" in
  impl-x) mkdir -p out && echo built > out/a.txt
          sed -i.bak 's/^- \[ \] build thing/- [x] build thing/' state/fix_plan.md && rm -f state/fix_plan.md.bak
          echo implemented; exit 0;;
  judge-x) echo "VERDICT: SHIP"; exit 0;;
  *) echo "stub: unexpected model '$model'" >&2; exit 1;;
esac
STUB
chmod +x "$WORK/stub-claude"
# A `codex` on PATH that REFUSES to run and records the fact. Reaching it would disprove the claim.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/codex" <<'CSTUB'
#!/usr/bin/env bash
echo "CODEX-WAS-INVOKED: $*" >> "$CODEX_CALLS"
exit 97
CSTUB
chmod +x "$WORK/bin/codex"

T="$WORK/repo"; mkdir -p "$T"; cd "$T" || exit 1
git init -q -b main
git config core.autocrlf false
git config user.email v62@example.com
git config user.name "V62 Probe"
cp -r "$ROOT/harness" .
rm -rf harness/.runs harness/.worktrees
mkdir -p state
# EVERY phase with no dispatch site is routed to codex here. If any of them is honoured headlessly,
# the codex stub is invoked and this probe fails.
cat > harness/harness.config.json <<'JSON'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": {
    "plan":      { "model": "codex", "fallback": null },
    "explore":   { "model": "codex", "fallback": null },
    "docs":      { "model": "codex", "fallback": null },
    "implement": { "model": "impl-x", "fallback": null },
    "review":    { "model": "judge-x", "fallback": null },
    "codex":     { "model": null, "reasoningEffort": "high", "auth": "chatgpt", "timeoutSeconds": 60 }
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
git add -A && git commit -q -m init

export STUB_CALLS="$WORK/claude-calls.txt"; : > "$STUB_CALLS"
export CODEX_CALLS="$WORK/codex-calls.txt"; : > "$CODEX_CALLS"

echo "### arm 1: a loop run whose plan/explore/docs are ALL routed to codex"
PATH="$WORK/bin:$PATH" HARNESS_CLAUDE_CMD="$WORK/stub-claude" bash harness/loop.sh --mode auto --max 1 > "$WORK/loop.out" 2>&1
echo "    loop exit=$?"
cp "$WORK/loop.out" "$OUT/arm-1-loop.out" 2>/dev/null
echo "    models the claude arm was asked for: $(tr '\n' ' ' < "$STUB_CALLS")"
echo "    codex invocations recorded:          $(wc -l < "$CODEX_CALLS") $(cat "$CODEX_CALLS")"

if [ -s "$CODEX_CALLS" ]; then
  bad "codex WAS invoked — some phase honours one of plan/explore/docs headlessly, so doctor 10(i)'s table is wrong"
else
  ok "codex was never invoked: plan/explore/docs routed to codex are silently ignored by the loop"
fi
grep -q 'impl-x' "$STUB_CALLS"  && ok "the implement phase DID dispatch (the run really happened)" || bad "no implement call — the run did not reach a dispatch site at all, so the arm proves nothing"
grep -q 'judge-x' "$STUB_CALLS" && ok "the review phase DID dispatch (a second real dispatch site)"  || bad "no review call"

echo
echo "### arm 2: POSITIVE CONTROL — the same loop, with a codex route the engine DOES honour"
# Without this arm, "codex was never invoked" is equally consistent with a broken PATH stub. Route
# `review` to codex and the same stub MUST be reached.
jq '.models.review.model = "codex"' harness/harness.config.json > "$WORK/c2" && mv "$WORK/c2" harness/harness.config.json
git add -A && git commit -q -m "route review to codex"
sed -i.bak 's/^- \[x\] build thing/- [ ] build thing/' state/fix_plan.md && rm -f state/fix_plan.md.bak
git add -A && git commit -q -m "reopen task"
: > "$CODEX_CALLS"; : > "$STUB_CALLS"
rm -rf harness/.runs
PATH="$WORK/bin:$PATH" HARNESS_CLAUDE_CMD="$WORK/stub-claude" bash harness/loop.sh --mode auto --max 1 > "$WORK/loop2.out" 2>&1
cp "$WORK/loop2.out" "$OUT/arm-2-loop.out" 2>/dev/null
echo "    codex invocations recorded: $(wc -l < "$CODEX_CALLS")"
if [ -s "$CODEX_CALLS" ]; then
  # NOTE what this does and does not say. The stub exits 97, so the engine's availability probe
  # (`codex login status`) fails and the phase falls back to Claude — arm 2 does NOT show a completed
  # codex exec. It shows the thing the control needs to show: a phase the engine HONOURS makes contact
  # with the codex binary, and an unhonoured one makes none at all. That contrast is the measurement.
  ok "the PATH stub IS reachable — arm 1's zero is a measurement, not a broken PATH"
  echo "      first contact: $(head -1 "$CODEX_CALLS" | cut -c1-120)"
  echo "      (an availability probe, not an exec — the stub exits 97 on purpose; see the comment above)"
else
  bad "codex not invoked even for a review route — the stub is unreachable and arm 1 proves NOTHING"
fi

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/arm-1-loop.out" "$OUT/arm-2-loop.out" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/arm-1-loop.out" "$OUT/arm-2-loop.out"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
