#!/usr/bin/env bash
# Arm H — the DIFFERENTIAL: the same write prompt, through the SHIPPED arg builder, before and after
# the fix, against the real CLI.
#
# This replaces an earlier pair of runs (pre-fix RED, post-fix GREEN in separate files). A
# fresh-context review made the point that decided the shape: the fix's first proof used a
# HAND-ASSEMBLED argv, which is not the artifact the CLI consumes in production. So both halves here
# come from `codex_args` itself — the PRE half sourced from the git blob at HEAD (never transcribed,
# so a copy-paste slip cannot make the differential agree with itself), the POST half from the
# working tree.
#
#   PRE  read-only + write prompt -> the file MUST appear   (reproduces the defect)
#   POST read-only + write prompt -> the file MUST NOT      (the fix binds)
#   POST workspace-write          -> the file MUST appear   (writers unaffected — without this the
#                                    "fix" could be "codex can no longer write anything")
#
# The file is the oracle; exit codes are not (codex may exit 0 having politely declined). Each case
# also prints the CLI's own `sandbox:`/`approval:` header, which is the mechanism.
#
# COST: three real codex calls. PROBE_SKIP_MODEL=1 skips the arm.
#   Run from the repo root:  bash state/evidence/2026-09-09-codex-invoke-live-fire/probes/builder-differential.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $PROBE_OUT_DIR redirects every output this script writes. skip-proof.sh sets it so a stub run
# cannot overwrite real captured evidence with a stub result (it did, once).
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$OUT/builder-differential.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0

if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   arm H skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi

WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT

# --- the two builders, both extracted rather than typed -------------------------------------------
git -C "$ROOT" show HEAD:plugin/engine/lib/invoke-codex.sh > "$WORK/pre.sh" 2>/dev/null || {
  echo "REFUSING: could not read the pre-fix lib from the git blob at HEAD"; exit 2; }
cp "$ROOT/plugin/engine/lib/invoke-codex.sh" "$WORK/post.sh"

argv_of() {  # $1 lib  $2 mode -> one arg per line
  ( set +u; . "$1"; codex_args "$2" "$WORK/x" "$WORK/x/.lastmsg" "" "" )
}
PRE_ARGV="$(argv_of "$WORK/pre.sh" read-only)"
POST_ARGV="$(argv_of "$WORK/post.sh" read-only)"

echo "### the two argv vectors (read-only), as the builders emit them"
echo "    PRE  (HEAD):        $(printf '%s ' $PRE_ARGV)"
echo "    POST (working tree): $(printf '%s ' $POST_ARGV)"
diff_only="$(diff <(printf '%s\n' "$PRE_ARGV") <(printf '%s\n' "$POST_ARGV") | grep '^[<>]' | sed 's/^[<>] //' | sort -u)"
echo "    they differ by:     $(printf '%s ' $diff_only)"
# Refuse to run if the difference is not exactly the approval override: if the two vectors were
# identical, both halves would agree and the differential would prove nothing.
# Compare against a SORTED expected set: `sort -u` above orders the two elements by byte value,
# not by their order in argv, so a hand-written literal in argv order fails for the wrong reason
# (it did on the first run).
expected="$(printf '%s\n' '-c' 'approval_policy="never"' | sort -u)"
if [ "$diff_only" != "$expected" ]; then
  echo "REFUSING: the pre/post argv differ by something other than the approval override:"
  printf '%s\n' "$diff_only" | sed 's/^/      /'
  echo "  expected exactly:"; printf '%s\n' "$expected" | sed 's/^/      /'
  exit 2
fi
echo "  ok   the ONLY difference is the approval override — nothing else varies between the halves"
echo

run_case() {  # $1 label  $2 lib  $3 mode  $4 logname  $5 expect-file(yes|no)
  local label="$1" lib="$2" mode="$3" logname="$4" want="$5"
  local d="$WORK/$logname"; mkdir -p "$d"
  ( cd "$d" && git init -q -b main && git config user.email a@b.c && git config user.name t \
    && echo seed > README.md && git add -A && git commit -q -m init )
  local out
  out="$( set +u; . "$lib"; invoke_codex "$mode" 'Create a file named codex-wrote-me.txt in the working root whose entire contents are the single line WRITE-TOKEN-5591. Do not change anything else. Then stop.' "$d" "$OUT/$logname.log" "" "" 300 )"
  local crc=$?
  local wrote=no; [ -f "$d/codex-wrote-me.txt" ] && wrote=yes
  echo "### $label"
  echo "    exit=$crc  header: $(grep -a -m1 '^sandbox:' "$OUT/$logname.log" | tr -d '\r') | $(grep -a -m1 '^approval:' "$OUT/$logname.log" | tr -d '\r')"
  echo "    WROTE: $wrote (required: $want)"
  local refusal; refusal="$(grep -a -m1 -i 'patch rejected\|blocked by read-only' "$OUT/$logname.log" | sed 's/^.*ERROR //' | tr -d '\r')"
  [ -n "$refusal" ] && echo "    CLI said: $refusal"
  if [ "$wrote" = "$want" ]; then echo "  ok   $label"; else echo "  FAIL $label — got WROTE=$wrote, required $want"; rc=1; fi
  echo
}

run_case "PRE  read-only  — the defect reproduces (a judge mutates the tree)" "$WORK/pre.sh"  read-only       h-pre-readonly   yes
run_case "POST read-only  — the fix binds (the same write is refused)"        "$WORK/post.sh" read-only       h-post-readonly  no
run_case "POST workspace-write — writers are unaffected"                      "$WORK/post.sh" workspace-write h-post-write     yes

echo "RESULT: arm H differential $([ "$rc" = 0 ] && echo GREEN || echo RED)"
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT"/h-pre-readonly.log "$OUT"/h-post-readonly.log "$OUT"/h-post-write.log >/dev/null 2>&1
exit "$rc"
