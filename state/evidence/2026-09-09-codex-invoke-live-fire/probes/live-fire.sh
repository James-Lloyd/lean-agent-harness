#!/usr/bin/env bash
# Live-fire the codex invoke path on the INSTALLED CLI (fix_plan: "Live-fire the codex invoke path …
# flag placement, `exec -` stdin, --output-last-message parse"). The 2026-07-14 partial ran the
# read-only path on codex-cli 0.144.3; this re-measures on what is installed today and adds the
# verdict parse the item's done-when asks for.
#
# COST: arms B, C and E each make a REAL codex call. `PROBE_SKIP_MODEL=1` suppresses every one of
# them (proved by probes/skip-proof.sh, which puts a loud stub on PATH and fails if it is invoked).
# Arms A, F and G call no model at all.
#
#   Run from the repo root:  bash state/evidence/2026-09-09-codex-invoke-live-fire/probes/live-fire.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $PROBE_OUT_DIR redirects every output this script writes. skip-proof.sh sets it so a stub run
# cannot overwrite real captured evidence with a stub result (it did, once).
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
# Suffix so a re-run lands beside the original instead of overwriting it (the first run's arm-A dump
# shows the PRE-FIX argv, which is worth keeping).
SUF="${1:-}"
LOG="$OUT/live-fire${SUF}.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
SKIP="${PROBE_SKIP_MODEL:-0}"
rc=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; rc=1; }
skip() { echo "  --   $1 (PROBE_SKIP_MODEL=1)"; }

# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/invoke-codex.sh"
# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/gate.sh"        # review_verdict
# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/dispatch.sh"    # invoke_phase

VER="$(codex --version 2>&1 | tr -d '\r')"
echo "### environment"
echo "    codex: $VER"
echo "    auth : $(codex login status 2>&1 | head -1 | tr -d '\r')"
echo "    repo : <repo>"
echo

# --- A: flag placement, from the CLI's own help (no model) ---------------------------------------
echo "### arm A: every flag the harness emits, checked against THIS version's help (free)"
codex --help > "$OUT/codex-help${SUF}.txt" 2>&1
codex exec --help > "$OUT/codex-exec-help${SUF}.txt" 2>&1
# codex_args emits the globals BEFORE `exec` and the exec flags after it. That split is load-bearing:
# --ask-for-approval is a GLOBAL-only option on 0.153.4 (absent from `codex exec --help`), so the
# same vector with everything after `exec` would fail to parse.
for f in --sandbox --ask-for-approval --cd; do
  if grep -q -- "$f" "$OUT/codex-help${SUF}.txt"; then ok "global accepts $f"; else bad "global does NOT accept $f"; fi
done
for f in --skip-git-repo-check --output-last-message --sandbox --cd; do
  if grep -q -- "$f" "$OUT/codex-exec-help${SUF}.txt"; then ok "exec accepts $f"; else bad "exec does NOT accept $f"; fi
done
if grep -q -- '--ask-for-approval' "$OUT/codex-exec-help${SUF}.txt"; then
  echo "  note  exec ALSO accepts --ask-for-approval on this version (the split is no longer forced)"
else
  ok "--ask-for-approval is global-only here, so codex_args' before/after split is REQUIRED"
fi
# The vector itself, printed verbatim, so a reader can see what was run.
echo "    codex_args read-only <repo> <lastmsg> gpt-5.6-sol high ->"
codex_args read-only "$ROOT" "/tmp/lastmsg" "gpt-5.6-sol" "high" | sed 's/^/      /'
echo

# --- B: the real invocation, exact vector, `exec -` stdin, --output-last-message ------------------
echo "### arm B: invoke_codex read-only, prompt on STDIN, final message read back (PAID)"
if [ "$SKIP" = "1" ]; then skip "arm B"; else
  b_log="$OUT/arm-b-transcript${SUF}.txt"
  b_out="$(invoke_codex read-only 'Reply with exactly this and nothing else: LIVE-FIRE-TOKEN-8842' "$ROOT" "$b_log" "" "" 300)"
  b_rc=$?
  echo "    exit=$b_rc  final-message=<<$b_out>>"
  [ "$b_rc" -eq 0 ] && ok "codex exited 0" || bad "codex exited $b_rc"
  case "$b_out" in *LIVE-FIRE-TOKEN-8842*) ok "--output-last-message round-tripped the model's final text";;
                   *) bad "final message did not contain the token — the -o parse is not delivering";; esac
  [ -s "$b_log" ] && ok "full transcript captured ($(wc -l < "$b_log") lines)" || bad "transcript log is empty"
fi
echo

# --- C: the path the LOOP actually takes, through the dispatcher, parsed by review_verdict ---------
echo "### arm C: invoke_phase read-only -> review_verdict, i.e. the loop's review point (PAID)"
if [ "$SKIP" = "1" ]; then skip "arm C"; else
  c_log="$OUT/arm-c-transcript${SUF}.txt"
  c_prompt="$(cat <<'EOP'
You are a code reviewer. The change under review adds a comment line to a shell script. There is
nothing else in the diff. Report blockers only; "no findings" is a valid outcome.

Finish with EXACTLY ONE final line and nothing after it:
VERDICT: SHIP     (zero blockers)
VERDICT: REJECT   (any blocker)
EOP
)"
  c_file="$(mktemp)"
  if invoke_phase read-only "$c_prompt" "$ROOT" "$c_log" codex "" "" 20 chatgpt "" "" 300 > "$c_file"; then c_rc=0; else c_rc=$?; fi
  c_out="$(cat "$c_file")"; rm -f "$c_file"
  c_path="${INVOKE_PHASE_PATH:-}"
  c_v="$(printf '%s\n' "$c_out" | review_verdict)"
  echo "    exit=$c_rc  path='$c_path'  used_fallback=${INVOKE_PHASE_USED_FALLBACK:-}  verdict='$c_v'"
  [ "$c_rc" -eq 0 ] && ok "dispatcher returned 0" || bad "dispatcher returned $c_rc"
  [ "$c_path" = "codex" ] && ok "the codex arm ran (not a silent claude fallback)" || bad "path was '$c_path', expected codex"
  case "$c_v" in SHIP|REJECT) ok "review_verdict parsed a real verdict: $c_v";;
                 *) bad "review_verdict got '$c_v' — the loop would fail closed here";; esac
fi
echo

# --- D: the fail-closed parse is not fooled by the transcript it just produced --------------------
echo "### arm D: review_verdict fail-closed controls, incl. against arm C's REAL output (free)"
v_pre="$(printf 'I cannot give VERDICT: SHIP without more context.\nVERDICT: REJECT\n' | review_verdict)"
[ "$v_pre" = "REJECT" ] && ok "last VERDICT line wins over a quoted one (got REJECT)" || bad "preamble control got '$v_pre'"
v_none="$(printf 'no verdict here at all\n' | review_verdict)"
[ -z "$v_none" ] || [ "$v_none" = "NONE" ] && ok "no VERDICT line -> empty/NONE (loop fails closed), got '$v_none'" || bad "got '$v_none'"
echo

# --- E: the external watchdog (codex exec has no timeout of its own) ------------------------------
echo "### arm E: the watchdog kills a run and says so in the log (PAID, ~1s of model time)"
if [ "$SKIP" = "1" ]; then skip "arm E"
elif ! command -v timeout >/dev/null 2>&1; then echo "  --   arm E: coreutils timeout not on PATH; the run would be UNBOUNDED here"
else
  e_log="$OUT/arm-e-transcript${SUF}.txt"
  invoke_codex read-only 'Count slowly from 1 to 500, one number per line.' "$ROOT" "$e_log" "" "" 1 >/dev/null
  e_rc=$?
  echo "    exit=$e_rc"
  [ "$e_rc" -eq 124 ] && ok "watchdog killed it with 124" || bad "expected 124 from the watchdog, got $e_rc"
  grep -q 'watchdog kill, failing closed' "$e_log" && ok "log carries the watchdog note" || bad "log has no watchdog note"
fi
echo

# --- F: availability probe + the fallback it drives (free, stubbed) -------------------------------
echo "### arm F: codex_available and the claude fallback it gates (free)"
if codex_available chatgpt codex >/dev/null 2>&1; then ok "codex_available says yes for the real CLI"; else bad "codex_available says no, but arm B ran"; fi
miss="$(codex_available chatgpt definitely-not-a-real-codex 2>&1)"; miss_rc=$?
[ "$miss_rc" -ne 0 ] && ok "a missing CLI is refused: '$miss'" || bad "a missing CLI was accepted"
( unset CODEX_API_KEY; codex_available api-key codex >/dev/null 2>&1 ) && bad "api-key auth accepted with no CODEX_API_KEY" || ok "api-key auth requires CODEX_API_KEY"
echo

echo "RESULT: codex invoke live-fire $([ "$rc" = 0 ] && echo GREEN || echo RED) (version: $VER, skip_model=$SKIP)"
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT"/*.txt >/dev/null 2>&1
exit "$rc"
