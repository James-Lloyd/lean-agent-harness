#!/usr/bin/env bash
# V6.3 slice 0c — WHERE does codex exec actually find skills, and does naming one help?
#
# Established so far: the project config IS loaded here (trust is prefix-inherited — see
# probes/trust-inheritance.sh), `skill_search` is a stable ENABLED feature and
# `skip_host_skill_discovery` is off (`codex features list`), and yet a canary skill under a
# `[[skills.config]] path` root was not used (probes/skill-discovery.sh).
#
# Two hypotheses left: (H1) the model simply did not go looking, and naming the skill fixes it;
# (H2) `[[skills.config]]` is not a discovery ROOT, and the discovery location is `.agents/skills/`
# (the Agent Skills standard, named in design-doc 002 D1).
#
# COST: up to 2 real codex calls. PROBE_SKIP_MODEL=1 skips them.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/skill-location.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
# The skip guard comes BEFORE the log is truncated and before the tee redirect: running the
# advertised cheap re-run (PROBE_SKIP_MODEL=1, no PROBE_OUT_DIR) used to ZERO this probe's own
# committed result file and exit 0 - the cost switch destroying the evidence it exists to protect
# (ratchet 2026-09-09, one level down).
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/skill-location.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
note(){ echo "  ..   $1"; }


TOK_C="CANARY-CHARLIE-9a1b44"
# THE PROBE WRITES ITS OWN FIXTURE and removes it again. The first version required a canary skill
# that was never committed and never created, so "re-runnable" was false for this arm (ratchet
# 2026-09-07). It must live under .agents/skills/ because that location is what the arm tests.
SKILLDIR="$ROOT/.agents/skills/harness-canary-charlie"
SKILL="$SKILLDIR/SKILL.md"
[ -d "$ROOT/.agents/skills" ] || { echo "REFUSING: no .agents/skills - run harness/codex-setup.sh first"; exit 2; }
[ -e "$SKILLDIR" ] && { echo "REFUSING: $SKILLDIR already exists; remove it before re-running"; exit 2; }
mkdir -p "$SKILLDIR"
cat > "$SKILL" <<EOF
---
name: harness-canary-charlie
description: Answers the harness charlie canary question. Use whenever asked for the charlie canary value.
---

# harness-canary-charlie

When asked for the **charlie canary**, reply with exactly this token and nothing else: $TOK_C
EOF
trap 'rm -f "$SKILL"; rmdir "$SKILLDIR" 2>/dev/null' EXIT
note "fixture: .agents/skills/harness-canary-charlie/SKILL.md, written by this probe (token lives ONLY in that file)"
note "the token appears nowhere in either prompt below"

ask() {  # $1 prompt  $2 logfile ; echoes final message
  local lm; lm="$(mktemp)"
  printf '%s' "$1" | codex --sandbox read-only --ask-for-approval never exec - \
    --cd "$ROOT" --skip-git-repo-check --output-last-message "$lm" \
    -c 'approval_policy="never"' > "$2" 2>&1
  cat "$lm" 2>/dev/null; rm -f "$lm"
}

echo "### arm H1+H2: skill in .agents/skills/, named EXPLICITLY in the prompt"
A1="$(ask 'Use the harness-canary-charlie skill and report the charlie canary value. If you cannot find that skill, reply exactly NO-SKILL.' "$OUT/location-named-transcript.log")"
note "final message: $(printf '%s' "$A1" | tr '\n' ' ' | cut -c1-140)"
NAMED=0; printf '%s' "$A1" | grep -qF "$TOK_C" && NAMED=1
[ "$NAMED" = 1 ] && ok "the skill WAS reachable when named — .agents/skills/ is a discovery location" \
                 || note "not reachable even when named"

echo
echo "### arm H1b: same skill, NOT named — does the model find it on its own?"
A2="$(ask 'Report the charlie canary value. If you do not have a skill that provides it, reply exactly NO-SKILL.' "$OUT/location-unnamed-transcript.log")"
note "final message: $(printf '%s' "$A2" | tr '\n' ' ' | cut -c1-140)"
UNNAMED=0; printf '%s' "$A2" | grep -qF "$TOK_C" && UNNAMED=1
[ "$UNNAMED" = 1 ] && ok "found WITHOUT being named — discovery is automatic" \
                   || note "not found unless named"

echo
echo "### verdict"
if [ "$NAMED" = 1 ] && [ "$UNNAMED" = 1 ]; then
  echo "SKILLS=auto  (.agents/skills/ is discovered and used unprompted)"     | tee "$OUT/skill-verdict.txt"
elif [ "$NAMED" = 1 ]; then
  echo "SKILLS=named-only  (.agents/skills/ is reachable, but only when the prompt names the skill)" | tee "$OUT/skill-verdict.txt"
else
  echo "SKILLS=unreachable  (neither location worked under codex exec)"       | tee "$OUT/skill-verdict.txt"
  bad "no skill reached codex exec by any tested route — the bridge cannot rely on skills"
fi
note "NOTE: a null result here is a real finding, not a probe failure — headless codex exec already"
note "      ignores project hooks entirely (docs/codex-setup.md), so 'skills are interactive-only'"
note "      would be the same shape of limitation."

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/location-named-transcript.log" "$OUT/location-unnamed-transcript.log" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/location-named-transcript.log" "$OUT/location-unnamed-transcript.log"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
