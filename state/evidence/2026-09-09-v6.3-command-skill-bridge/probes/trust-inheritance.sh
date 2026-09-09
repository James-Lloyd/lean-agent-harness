#!/usr/bin/env bash
# V6.3 slice 0b — IS PROJECT TRUST INHERITED BY A SUBDIRECTORY?
#
# The first discovery run concluded "skills do not load". That conclusion was unsound: an UNTRUSTED
# project skips its whole config.toml (docs/codex-setup.md), so the temp project's skills roots were
# never read. Before re-testing skills, establish which paths are trusted at all.
#
# `~/.codex/config.toml` carries a `[projects.'<home>\repos\harness']` trust entry (paths there are
# lowercased). This worktree lives BELOW that path, under `.claude/worktrees/`.
# If trust is prefix-inherited, the worktree's own generated .codex/config.toml is honoured and the
# skills question can be answered here with no change to the user's global config. If it is exact-match,
# it cannot — and that is itself a fact the bridge design has to account for, because every session of
# this repo runs in a worktree.
#
# Method: put an observable, non-skill setting in the project config and read the CLI's own header
# back (ratchet: assert the tool's report of its effective state, never the file you wrote).
# `model_reasoning_effort` is ideal — it prints in the header and needs no model pin.
#
# COST: 1 real codex call. PROBE_SKIP_MODEL=1 skips it.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/trust-inheritance.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
# The skip guard comes BEFORE the log is truncated and before the tee redirect: running the
# advertised cheap re-run (PROBE_SKIP_MODEL=1, no PROBE_OUT_DIR) used to ZERO this probe's own
# committed result file and exit 0 - the cost switch destroying the evidence it exists to protect
# (ratchet 2026-09-09, one level down).
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/trust-inheritance.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
note(){ echo "  ..   $1"; }


CFG="$ROOT/.codex/config.toml"
[ -f "$CFG" ] || { echo "REFUSING: no generated .codex/config.toml in this worktree — run harness/codex-setup.sh first"; exit 2; }
BAK="$(mktemp)"; cp "$CFG" "$BAK"
restore() { cp "$BAK" "$CFG"; rm -f "$BAK"; }
trap restore EXIT

echo "### environment"
note "worktree : <repo>"
note "trusted paths in ~/.codex/config.toml that could cover it:"
grep -n "^\[projects\." "$HOME/.codex/config.toml" 2>/dev/null | sed 's/^/       /' | grep -i "repos.harness" || note "       (none matching repos/harness)"
echo

# A setting that PRINTS in the header, PREPENDED to the generated project config.
# PREPENDED, not appended: in TOML a bare key belongs to the table header above it, and this file ends
# with `[[skills.config]]`. The first version of this arm appended the key, which put it INSIDE that
# table, where it does nothing whatever the trust state is — an arm that reports "not applied" for a
# reason that has nothing to do with what it claims to measure.
TMPCFG="$(mktemp)"
{ printf 'model_reasoning_effort = "low"\n\n'; cat "$CFG"; } > "$TMPCFG"
cp "$TMPCFG" "$CFG"; rm -f "$TMPCFG"
# Positive control on the fixture itself: the key must now precede every table header.
FIRST_TABLE="$(grep -n '^\[' "$CFG" | head -1 | cut -d: -f1)"
KEY_LINE="$(grep -n '^model_reasoning_effort' "$CFG" | head -1 | cut -d: -f1)"
if [ -n "$FIRST_TABLE" ] && [ -n "$KEY_LINE" ] && [ "$KEY_LINE" -lt "$FIRST_TABLE" ]; then
  ok "fixture is well-formed: the probe key (line $KEY_LINE) precedes the first table (line $FIRST_TABLE)"
else
  bad "fixture is malformed — the probe key is not at top level; the measurement below would be meaningless"
fi
echo "### arm 1: does the worktree's project config.toml take effect?"
printf 'Reply with the single word OK.' | codex --sandbox read-only --ask-for-approval never exec - \
  --cd "$ROOT" --skip-git-repo-check --output-last-message "$(mktemp)" \
  -c 'approval_policy="never"' > "$OUT/trust-transcript.log" 2>&1
HDR="$(grep -m1 -E '^reasoning effort:' "$OUT/trust-transcript.log" | tr -d '\r')"
note "header: $HDR"
note "(the project config asks for 'low'; nothing on the command line sets effort)"
if [ "$HDR" = "reasoning effort: low" ]; then
  ok "TRUST IS INHERITED — the worktree's own .codex/config.toml is honoured"
  echo "TRUST=inherited" > "$OUT/trust-verdict.txt"
elif [ -n "$HDR" ]; then
  ok "measured: the project config is NOT applied (header says '$HDR', not 'low')"
  note "=> trust is exact-match, so a worktree is untrusted even under a trusted parent"
  echo "TRUST=exact-match" > "$OUT/trust-verdict.txt"
else
  bad "no reasoning-effort line in the transcript — cannot tell; the arm proves nothing"
fi

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)  (this arm REPORTS a fact; either verdict is a pass)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/trust-transcript.log" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/trust-transcript.log"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
