#!/usr/bin/env bash
# Arm G — the LOOP's review point, live, with the judge routed to the real codex CLI.
#
# Arm C proved the dispatcher hop (invoke_phase -> codex -> final message -> review_verdict). This
# arm proves the wrapper around it: a real `harness/loop.sh --mode auto` iteration in a throwaway
# repo, implementer stubbed (free), REVIEW routed to `"codex"`. What only this arm can show is the
# loop-level contract — the ledger line recording path=codex with a parsed verdict, a transcript on
# disk, and the judge leaving the tree exactly as it found it.
#
# Scaffolding is lifted from harness/tests/loop-review-test.sh (same stub-claude trick, same
# throwaway repo) so the only difference from the suite's own coverage is that the judge is REAL.
#
# COST: one real codex call. PROBE_SKIP_MODEL=1 skips the whole arm.
#   Run from the repo root:  bash state/evidence/2026-09-09-codex-invoke-live-fire/probes/loop-review-codex.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $PROBE_OUT_DIR redirects every output this script writes. skip-proof.sh sets it so a stub run
# cannot overwrite real captured evidence with a stub result (it did, once).
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$OUT/loop-review-codex.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }

if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   arm G skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
command -v jq >/dev/null 2>&1 || { echo "REFUSING: jq not installed"; exit 2; }

export HARNESS_ENGINE="$ROOT/plugin/engine"
WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT

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
  *) echo "stub: unexpected model '$model' — the codex judge must NOT come through claude" >&2; exit 1;;
esac
STUB
chmod +x "$WORK/stub-claude"

T="$WORK/repo"; mkdir -p "$T"; cd "$T" || exit 1
git init -q -b main
git config core.autocrlf false
git config user.email loop-codex@example.com
git config user.name "Loop Codex Probe"
cp -r "$ROOT/harness" .
rm -rf harness/.runs harness/.worktrees
mkdir -p state
cat > harness/harness.config.json <<'JSON'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": {
    "implement": { "model": "impl-x", "fallback": null },
    "review":    { "model": "codex", "fallback": null },
    "codex":     { "model": null, "reasoningEffort": null, "auth": "chatgpt", "timeoutSeconds": 300 }
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

echo "### arm G: harness/loop.sh --mode auto, review routed to the real codex CLI"
HARNESS_CLAUDE_CMD="$WORK/stub-claude" bash harness/loop.sh --mode auto --max 1 > "$WORK/loop.out" 2>&1
loop_rc=$?
cp "$WORK/loop.out" "$OUT/arm-g-loop.out" 2>/dev/null
LEDGER=harness/.runs/run-001/ledger.jsonl
echo "    loop exit=$loop_rc"
echo "    ledger:"; sed 's/^/      /' "$LEDGER" 2>/dev/null

line="$(grep '"result":"review"' "$LEDGER" 2>/dev/null | tail -1)"
if [ -z "$line" ]; then bad "no review line in the ledger — the review point never ran"; else
  path="$(printf '%s' "$line" | jq -r '.path // ""' 2>/dev/null)"
  verdict="$(printf '%s' "$line" | jq -r '.verdict // ""' 2>/dev/null)"
  model="$(printf '%s' "$line" | jq -r '.model // ""' 2>/dev/null)"
  [ "$path" = "codex" ]  && ok "ledger records path=codex (the real CLI judged it)" || bad "ledger path='$path', expected codex"
  [ "$model" = "codex" ] && ok "ledger records the routed model" || bad "ledger model='$model'"
  case "$verdict" in
    SHIP|REJECT) ok "the loop parsed a real verdict from codex: $verdict";;
    ERROR)       bad "verdict=ERROR — the invocation failed; see the transcript";;
    *)           bad "verdict='$verdict' — no clear verdict parsed (the loop fails closed here)";;
  esac
fi

t="$(ls harness/.runs/run-001/review-after-*.log 2>/dev/null | head -1)"
[ -n "$t" ] && [ -s "$t" ] && { ok "reviewer transcript written ($(basename "$t"), $(wc -l < "$t") lines)"; cp "$t" "$OUT/arm-g-review-transcript.log"; } \
                           || bad "no reviewer transcript on disk"
# A judge must not mutate what it judges: the loop hard-resets to the reviewed HEAD either way.
[ -z "$(git status --porcelain)" ] && ok "tree clean after the judge ran (read-only discipline held)" || bad "tree dirty after review: $(git status --porcelain | head -3)"

echo
echo "RESULT: arm G $([ "$rc" = 0 ] && echo GREEN || echo RED)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/arm-g-loop.out" "$OUT/arm-g-review-transcript.log" >/dev/null 2>&1
exit "$rc"
