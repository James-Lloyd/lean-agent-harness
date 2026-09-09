#!/usr/bin/env bash
# V6.3 — THE BRIDGE ITSELF: does codex exec LOAD a generated harness command-skill and ACT on it?
#
# The done-when for this slice is deliberately "loaded and acted on, not merely emitted" (ratchet
# 2026-09-05: verify a generated artifact by making the foreign tool load it and act on it).
# Asserting the emitted text would prove only that the generator can write files.
#
# The question put to codex is answerable ONLY from the generated `harness-review` skill's body — it
# asks for the harness's verdict vocabulary and its doer/judge rule, which appear in no prompt here.
# Arm C is the control: the same question with the generated skills moved aside must NOT answer.
#
# COST: 2 real codex calls. PROBE_SKIP_MODEL=1 skips them.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/bridge-live-fire.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
# The skip guard comes BEFORE the log is truncated and before the tee redirect: running the
# advertised cheap re-run (PROBE_SKIP_MODEL=1, no PROBE_OUT_DIR) used to ZERO this probe's own
# committed result file and exit 0 - the cost switch destroying the evidence it exists to protect
# (ratchet 2026-09-09, one level down).
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/bridge-live-fire.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
note(){ echo "  ..   $1"; }


SK="$ROOT/.agents/skills"
[ -f "$SK/harness-review/SKILL.md" ] || { echo "REFUSING: no generated harness-review skill - run harness/codex-setup.sh first"; exit 2; }

echo "### what the generator produced"
note "skills dir: .agents/skills ($(find "$SK" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ') skills)"
note "commands bridged: $(find "$SK" -mindepth 1 -maxdepth 1 -type d -name 'harness-*' | wc -l | tr -d ' ')"
find "$SK" -mindepth 1 -maxdepth 1 -type d | sed 's#.*/#       #' | sort | head -30
echo

ask() {  # $1 prompt  $2 logfile
  local lm; lm="$(mktemp)"
  printf '%s' "$1" | codex --sandbox read-only --ask-for-approval never exec - \
    --cd "$ROOT" --skip-git-repo-check --output-last-message "$lm" \
    -c 'approval_policy="never"' > "$2" 2>&1
  cat "$lm" 2>/dev/null; rm -f "$lm"
}
# Answerable only from the skill body. Neither the verdict words nor the rule appear in the prompt.
Q='Using the harness review skill available to you, answer in two short lines: (1) the exact verdict keywords that review is required to end with, and (2) the one-sentence rule the harness gives about who may review a change. If you have no such skill, reply exactly NO-SKILL.'

echo "### arm B1: the generated bridge in place"
A1="$(ask "$Q" "$OUT/bridge-transcript.log")"
note "final message: $(printf '%s' "$A1" | tr '\n' ' ' | cut -c1-200)"
# SHIP/REJECT is the harness's verdict contract; the doer/judge rule is its review invariant. Both
# live in the generated skill body and nowhere in the prompt.
# CASE-INSENSITIVE on purpose. The first version of this arm grepped for uppercase SHIP/REJECT and
# went red on a CORRECT answer ("ship / fix-then-ship / reject") - the defect was in the checker, not
# the bridge. The contract is three-valued, so require the middle verdict too: a model reciting a
# generic ship/reject vocabulary from prior knowledge would not produce FIX-THEN-SHIP, which is this
# harness's own.
G_SHIP=0; G_JUDGE=0
printf '%s' "$A1" | grep -qiE 'fix-then-ship' && printf '%s' "$A1" | grep -qiE 'reject' && G_SHIP=1
printf '%s' "$A1" | grep -qiE 'doer|not the judge|did not write|author' && G_JUDGE=1
[ "$G_SHIP" = 1 ]  && ok "codex reported the harness's own three-valued verdict contract (incl. FIX-THEN-SHIP) - it read the skill body" \
                   || bad "the harness's verdict vocabulary did not come back - the skill was not loaded or not used"
[ "$G_JUDGE" = 1 ] && ok "codex reported the doer-is-not-the-judge rule - it ACTED on the skill's content" \
                   || bad "the doer/judge rule did not come back"

echo
echo "### arm C: NEGATIVE CONTROL - the same question with the generated skills moved aside"
MOVED="$ROOT/.agents/skills-moved-aside"
mv "$SK" "$MOVED"
restore() { [ -d "$MOVED" ] && mv "$MOVED" "$SK"; }
trap restore EXIT
AC="$(ask "$Q" "$OUT/bridge-control-transcript.log")"
restore; trap - EXIT
note "final message: $(printf '%s' "$AC" | tr '\n' ' ' | cut -c1-200)"
# The control must not be able to answer from the repo at large. It CAN still read files, so the
# honest bar is the skill-absence signal, not mere absence of the words.
if printf '%s' "$AC" | grep -qF 'NO-SKILL'; then
  ok "without the generated skills codex reports NO-SKILL - arm B1's answer came from the bridge"
else
  note "control did not say NO-SKILL; it answered from the repo instead (codex can read files)"
  note "answer was: $(printf '%s' "$AC" | tr '\n' ' ' | cut -c1-160)"
  bad "the control could answer without the skill, so arm B1 does not isolate the bridge - tighten the question"
fi

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/bridge-transcript.log" "$OUT/bridge-control-transcript.log" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/bridge-transcript.log" "$OUT/bridge-control-transcript.log"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
