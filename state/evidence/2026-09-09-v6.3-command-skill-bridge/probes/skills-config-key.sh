#!/usr/bin/env bash
# V6.3 slice 0d — IS `[[skills.config]] path` A DISCOVERY ROOT AT ALL?
#
# This is the load-bearing question for the whole `.codex/` layer: the harness has emitted
# `[[skills.config]] path = <plugin>/skills, enabled = true` since slice V3, and the 2026-09-06
# re-verification confirmed only that the `enabled` KEY is required — never that a skill at that path
# is reachable. probes/skill-discovery.sh found two canaries there unreachable in a trusted project,
# but its roots were under /tmp, OUTSIDE the trusted path, which is a confound (that same confound
# already produced one wrong conclusion in this dir).
#
# This arm removes it: the skills root is INSIDE the trusted repo, and the ONLY route to the token is
# the `[[skills.config]]` entry. `.agents/skills/` is a proven auto-discovery location (slice 0c), so
# the fixture deliberately lives somewhere else.
#
# COST: 2 real codex calls (one measurement, one control). PROBE_SKIP_MODEL=1 skips them.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/skills-config-key.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
# The skip guard comes BEFORE the log is truncated and before the tee redirect: running the
# advertised cheap re-run (PROBE_SKIP_MODEL=1, no PROBE_OUT_DIR) used to ZERO this probe's own
# committed result file and exit 0 - the cost switch destroying the evidence it exists to protect
# (ratchet 2026-09-09, one level down).
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/skills-config-key.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
note(){ echo "  ..   $1"; }


TOK_D="CANARY-DELTA-5e7c02"
# THE PROBE WRITES ITS OWN FIXTURE. The first version required a `generated-skills-probe/` directory
# that was never committed and never created, so "re-runnable" was false for this arm (ratchet
# 2026-09-07: the re-runnable probe contains the arm that produced it). It lives in a temp dir so a
# re-run cannot leave litter in the repo, and deliberately NOT under `.agents/skills/`, which is a
# proven auto-discovery location and would make the arm answer through the very route it is testing.
FIXROOT="$(mktemp -d)"
FIX="$FIXROOT/skills-root"
mkdir -p "$FIX/harness-canary-delta"
cat > "$FIX/harness-canary-delta/SKILL.md" <<EOF
---
name: harness-canary-delta
description: Answers the harness delta canary question. Use whenever asked for the delta canary value.
---

# harness-canary-delta

When asked for the **delta canary**, reply with exactly this token and nothing else: $TOK_D
EOF
CFG="$ROOT/.codex/config.toml"
[ -f "$CFG" ] || { echo "REFUSING: no generated .codex/config.toml — run harness/codex-setup.sh first"; exit 2; }
BAK="$(mktemp)"; cp "$CFG" "$BAK"
trap 'cp "$BAK" "$CFG"; rm -f "$BAK"; rm -rf "$FIXROOT"' EXIT

fwd() { printf '%s' "$1" | sed 's#\\#/#g'; }
ask() {  # $1 prompt  $2 logfile
  local lm; lm="$(mktemp)"
  printf '%s' "$1" | codex --sandbox read-only --ask-for-approval never exec - \
    --cd "$ROOT" --skip-git-repo-check --output-last-message "$lm" \
    -c 'approval_policy="never"' > "$2" 2>&1
  cat "$lm" 2>/dev/null; rm -f "$lm"
}
Q='Report the delta canary value. If you do not have a skill that provides it, reply exactly NO-SKILL.'

note "fixture root: a temp dir written by this probe, declared as a [[skills.config]] path (NOT .agents/skills)"
note "SCOPE: only the ROOT-OF-SKILL-DIRS form is tested - the shape the harness actually emits."
note "       `path` pointing at a single skill DIRECTORY is untested, and n=1 per arm against a"
note "       nondeterministic model. The load-bearing claim (the harness's own stanza delivers"
note "       nothing) is what these arms support."
note "the token appears nowhere in the prompt"

echo "### arm 1: the fixture root declared via [[skills.config]]"
# IN-RUN PREMISE WITNESS. This arm concludes "inert" from a NULL result, and a null result is exactly
# what a config that was never loaded also looks like. The premise (this project's config IS honoured)
# was established by a DIFFERENT run with different file content, which is not good enough for the
# repo's own rule that a null result gets its premise checked. `model_reasoning_effort = "low"` is
# carried at TOP LEVEL of the very same file, so the transcript's own header proves the file was read.
printf 'model_reasoning_effort = "low"\n\n[features]\nhooks = true\n\n[[skills.config]]\npath = "%s"\nenabled = true\n' "$(fwd "$FIX")" > "$CFG"
cp "$CFG" "$OUT/config-key-arm1.toml"
A1="$(ask "$Q" "$OUT/config-key-arm1-transcript.log")"
note "final message: $(printf '%s' "$A1" | tr '\n' ' ' | cut -c1-140)"
VIA_CFG=0; printf '%s' "$A1" | grep -qF "$TOK_D" && VIA_CFG=1
# The witness: same file, same run. If this says anything but `low`, the config was not loaded and the
# arm is measuring nothing at all -- so it is a hard stop, not a note.
HDR1="$(grep -m1 -E '^reasoning effort:' "$OUT/config-key-arm1-transcript.log" 2>/dev/null | tr -d '\r')"
note "premise witness (same file, same run): $HDR1"
if [ "$HDR1" = "reasoning effort: low" ]; then
  ok "the config file WAS loaded this run - a NO-SKILL below is about the stanza, not about the file"
else
  bad "the project config was NOT loaded (header '$HDR1', expected 'low') - this arm cannot conclude anything"
fi

echo
echo "### arm 2: POSITIVE CONTROL — the same fixture moved under .agents/skills/"
# Proves the fixture skill is well-formed and reachable BY SOME ROUTE. Without this, arm 1's silence
# could just mean the SKILL.md is malformed rather than that the config key is inert.
printf '[features]\nhooks = true\n' > "$CFG"
cp -r "$FIX/harness-canary-delta" "$ROOT/.agents/skills/" 2>/dev/null
A2="$(ask "$Q" "$OUT/config-key-arm2-transcript.log")"
rm -rf "$ROOT/.agents/skills/harness-canary-delta"
note "final message: $(printf '%s' "$A2" | tr '\n' ' ' | cut -c1-140)"
VIA_AGENTS=0; printf '%s' "$A2" | grep -qF "$TOK_D" && VIA_AGENTS=1

echo
echo "### verdict"
if [ "$VIA_AGENTS" != 1 ]; then
  bad "the control failed — the fixture skill is unreachable even under .agents/skills/, so arm 1 measures nothing"
elif [ "$VIA_CFG" = 1 ]; then
  echo "SKILLS_CONFIG=works  ([[skills.config]] path IS a discovery root)" | tee "$OUT/skills-config-verdict.txt"
  ok "both routes work"
else
  echo "SKILLS_CONFIG=inert  (the same skill is found under .agents/skills/ and NOT via [[skills.config]])" | tee "$OUT/skills-config-verdict.txt"
  ok "measured: the config key parses and validates but delivers no skills to codex exec"
  note "=> the plugin/skills path the harness has emitted since V3 has never reached Codex"
fi

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)  (an 'inert' verdict is a finding, not a failure)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/config-key-arm1-transcript.log" "$OUT/config-key-arm2-transcript.log" "$OUT/config-key-arm1.toml" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/config-key-arm1-transcript.log" "$OUT/config-key-arm2-transcript.log" "$OUT/config-key-arm1.toml"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
