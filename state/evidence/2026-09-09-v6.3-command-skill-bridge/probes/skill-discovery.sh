#!/usr/bin/env bash
# V6.3 slice 0 — DOES CODEX ACTUALLY LOAD A SKILL FROM `[[skills.config]] path`?
#
# The harness has emitted that config stanza since slice V3 and re-verified in 2026-09-06 that the
# `enabled` key is required — but nothing has ever checked that a skill at that path is LOADED and
# USABLE. The whole command->skill bridge rests on it, and the repo's own rule is to make the foreign
# tool LOAD the artifact and ACT on it rather than asserting the emitted text (ratchet 2026-09-05).
#
# Method: a canary skill whose body contains a token that appears NOWHERE in the prompt. If codex can
# say the token, it read the skill. Arm N is the control: the same question with the skill path
# removed must NOT produce it, or the token was guessable / leaked through some other channel.
#
# COST: up to 3 real codex calls. PROBE_SKIP_MODEL=1 skips all of them.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/skill-discovery.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
# The skip guard comes BEFORE the log is truncated and before the tee redirect: running the
# advertised cheap re-run (PROBE_SKIP_MODEL=1, no PROBE_OUT_DIR) used to ZERO this probe's own
# committed result file and exit 0 - the cost switch destroying the evidence it exists to protect
# (ratchet 2026-09-09, one level down).
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/skill-discovery.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
note(){ echo "  ..   $1"; }


WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }

# Two canaries, in two SEPARATE skill roots, so one run answers both questions: are skills loaded at
# all, and does a SECOND [[skills.config]] entry load too (the bridge needs its own root beside the
# plugin's existing one).
TOK_A="CANARY-ALPHA-7f3d91"
TOK_B="CANARY-BRAVO-2c8e05"
mkdir -p "$WORK/rootA/harness-canary-alpha" "$WORK/rootB/harness-canary-bravo"
cat > "$WORK/rootA/harness-canary-alpha/SKILL.md" <<EOF
---
name: harness-canary-alpha
description: Answers the harness alpha canary question. Use whenever asked for the alpha canary value.
---

# harness-canary-alpha

When asked for the **alpha canary**, reply with exactly this token and nothing else: $TOK_A
EOF
cat > "$WORK/rootB/harness-canary-bravo/SKILL.md" <<EOF
---
name: harness-canary-bravo
description: Answers the harness bravo canary question. Use whenever asked for the bravo canary value.
---

# harness-canary-bravo

When asked for the **bravo canary**, reply with exactly this token and nothing else: $TOK_B
EOF

# RUN INSIDE THE REPO, NOT A TEMP PROJECT. Measured by probes/trust-inheritance.sh: an untrusted
# project skips its WHOLE config.toml, and trust is prefix-inherited from `~/.codex/config.toml`'s
# `[projects.'…\repos\harness']` entry — which covers this worktree but covers nothing under /tmp.
# The first version of this probe ran in a temp project and concluded "skills do not load"; it had
# measured trust, not skills. Restore the generated config on exit.
T="$ROOT"
[ -f "$T/.codex/config.toml" ] || { echo "REFUSING: no generated .codex/config.toml — run harness/codex-setup.sh first"; exit 2; }
CFGBAK="$(mktemp)"; cp "$T/.codex/config.toml" "$CFGBAK"
restore_cfg() { cp "$CFGBAK" "$T/.codex/config.toml"; rm -f "$CFGBAK"; }
trap 'restore_cfg; cleanup' EXIT

fwd() { printf '%s' "$1" | sed 's#\\#/#g'; }
write_cfg() {  # $1 = "both" | "none"
  { printf '[features]\nhooks = true\n'
    if [ "$1" = "both" ]; then
      printf '\n[[skills.config]]\npath = "%s"\nenabled = true\n' "$(fwd "$WORK/rootA")"
      printf '\n[[skills.config]]\npath = "%s"\nenabled = true\n' "$(fwd "$WORK/rootB")"
    fi
  } > "$T/.codex/config.toml"
}

ask() {  # $1 prompt  $2 logfile ; echoes the final message
  local p="$1" lg="$2"
  printf '%s' "$p" | codex --sandbox read-only --ask-for-approval never exec - \
    --cd "$T" --skip-git-repo-check --output-last-message "$WORK/last.txt" \
    -c 'approval_policy="never"' > "$lg" 2>&1
  cat "$WORK/last.txt" 2>/dev/null
}

# The prompt names the canaries but never contains a token. Anything that says one, read a skill.
PROMPT='Report the alpha canary and the bravo canary values. Reply with just the two values, one per line. If you do not have a skill that provides them, reply exactly: NO-SKILL'

echo "### arm 1: two [[skills.config]] roots, project config present"
write_cfg both
cp "$T/.codex/config.toml" "$OUT/arm-1-config.toml"
A1="$(ask "$PROMPT" "$WORK/a1.log")"
cp "$WORK/a1.log" "$OUT/arm-1-transcript.log" 2>/dev/null
note "final message: $(printf '%s' "$A1" | tr '\n' ' ' | cut -c1-120)"
# Report what the run itself says it loaded, not only what it answered.
note "config lines codex echoed: $(grep -ciE 'skill' "$WORK/a1.log" 2>/dev/null) mentioning 'skill'"
GOT_A=0; GOT_B=0
printf '%s' "$A1" | grep -qF "$TOK_A" && GOT_A=1
printf '%s' "$A1" | grep -qF "$TOK_B" && GOT_B=1
[ "$GOT_A" = 1 ] && ok "alpha canary returned — a skill under the FIRST root was loaded and acted on" \
                 || bad "alpha canary NOT returned — skills at [[skills.config]] path are not reaching codex exec"
[ "$GOT_B" = 1 ] && ok "bravo canary returned — a SECOND [[skills.config]] root loads too" \
                 || bad "bravo canary NOT returned — a second skills root does not load"

echo
echo "### arm N: NEGATIVE CONTROL — same question, no skills roots configured"
write_cfg none
AN="$(ask "$PROMPT" "$WORK/an.log")"
cp "$WORK/an.log" "$OUT/arm-n-transcript.log" 2>/dev/null
note "final message: $(printf '%s' "$AN" | tr '\n' ' ' | cut -c1-120)"
if printf '%s' "$AN" | grep -qF "$TOK_A" || printf '%s' "$AN" | grep -qF "$TOK_B"; then
  bad "a canary token appeared with NO skills configured — arm 1 proves nothing about skill loading"
else
  ok "no canary token without the skills roots — arm 1's tokens really came from the skill files"
fi

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/arm-1-transcript.log" "$OUT/arm-n-transcript.log" "$OUT/arm-1-config.toml" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/arm-1-transcript.log" "$OUT/arm-n-transcript.log" "$OUT/arm-1-config.toml"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
