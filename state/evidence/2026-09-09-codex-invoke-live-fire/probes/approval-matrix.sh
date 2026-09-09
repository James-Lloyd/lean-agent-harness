#!/usr/bin/env bash
# Arm I — why did a READ-ONLY codex judge write a file (arm H2)? Two candidate causes, and this
# separates them:
#   (1) the sandbox flag never reached exec — DISPROVED by the transcript headers: the harness's
#       global `--sandbox` does propagate (`sandbox: read-only` vs `workspace-write [workdir,...]`).
#   (2) the APPROVAL flag never reached exec — every transcript header says `approval: on-request`
#       though the harness passes `--ask-for-approval never`. And measured here: `codex exec` REJECTS
#       that flag outright (`error: unexpected argument '--ask-for-approval' found`, exit 2), so the
#       harness's global placement is the only one that parses at all — and it does not take effect.
#
# So: is an escalated apply_patch under read-only stopped when the approval policy is ACTUALLY never?
# `-c approval_policy="never"` is accepted by exec (it takes `-c key=value`), so that is the candidate
# fix. Each case runs the same write prompt in a fresh throwaway repo and reports the header the CLI
# printed plus whether the file appeared. The file is the oracle; the exit code is not.
#
# COST: three real codex calls (each small). PROBE_SKIP_MODEL=1 skips the arm.
#   Run from the repo root:  bash state/evidence/2026-09-09-codex-invoke-live-fire/probes/approval-matrix.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $PROBE_OUT_DIR redirects every output this script writes. skip-proof.sh sets it so a stub run
# cannot overwrite real captured evidence with a stub result (it did, once).
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$OUT/approval-matrix.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0

if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   arm I skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi

WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT

PROMPT='Create a file named codex-wrote-me.txt in the working root whose entire contents are the single line WRITE-TOKEN-5591. Do not change anything else. Then stop.'

echo "### does codex exec accept the approval flag at all? (free, parse only)"
codex exec --ask-for-approval never --help >"$WORK/parse.txt" 2>&1; p_rc=$?
echo "    exit=$p_rc  $(head -1 "$WORK/parse.txt")"
[ "$p_rc" -ne 0 ] && echo "  ok   exec REJECTS it — the global position is the only one that parses" \
                  || echo "  note exec accepts it on this version"
echo

case_run() {  # $1 label  $2 logname  ... rest: the codex argv AFTER `codex`
  local label="$1" logname="$2"; shift 2
  local d="$WORK/$logname"; mkdir -p "$d"
  ( cd "$d" && git init -q -b main && git config user.email a@b.c && git config user.name t \
    && echo x > README.md && git add -A && git commit -q -m init )
  local lastmsg="$d/.lastmsg"
  echo "### $label"
  echo "    argv: codex $*" | sed "s#$WORK#<tmp>#g"
  printf '%s' "$PROMPT" | timeout 300 codex "$@" > "$OUT/$logname.log" 2>&1
  local crc=$?
  local hdr_s hdr_a
  hdr_s="$(grep -m1 '^sandbox:' "$OUT/$logname.log" | tr -d '\r')"
  hdr_a="$(grep -m1 '^approval:' "$OUT/$logname.log" | tr -d '\r')"
  echo "    exit=$crc  header: ${hdr_s:-<none>} | ${hdr_a:-<none>}"
  if [ -f "$d/codex-wrote-me.txt" ]; then echo "    WROTE: yes  <- the tree was mutated"; else echo "    WROTE: no"; fi
  rm -f "$lastmsg"
}

# The harness's current vector, read-only (the judge configuration).
case_run "I1: harness vector — global --sandbox read-only --ask-for-approval never" i1 \
  --sandbox read-only --ask-for-approval never exec - --cd "$WORK/i1" --skip-git-repo-check -o "$WORK/i1/.lastmsg"

# Candidate fix: the approval policy as an exec-level config override.
case_run "I2: same, plus -c approval_policy=\"never\" after exec" i2 \
  --sandbox read-only --ask-for-approval never exec - --cd "$WORK/i2" --skip-git-repo-check -o "$WORK/i2/.lastmsg" \
  -c 'approval_policy="never"'

# Control: no sandbox flag at all, so the default is visible rather than assumed.
case_run "I3: control — no --sandbox flag (what exec defaults to here)" i3 \
  exec - --cd "$WORK/i3" --skip-git-repo-check -o "$WORK/i3/.lastmsg"

echo
echo "READ THIS OFF THE TABLE ABOVE: if I2 still WROTE, then on this platform read-only is not"
echo "enforced for apply_patch no matter how approval is set, and the harness's post-review hard"
echo "reset is the ONLY thing protecting a judged tree — which the docs must say plainly."
echo "RESULT: arm I recorded (no pass/fail — this arm measures, the write-up adjudicates)"
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT"/i1.log "$OUT"/i2.log "$OUT"/i3.log >/dev/null 2>&1
exit "$rc"
