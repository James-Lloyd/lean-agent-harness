#!/usr/bin/env bash
# Sharper test for should-fix #4: does `codex doctor` surface a project config that is BROKEN?
# Run it in the TRUSTED project with invalid TOML in .codex/config.toml — the state `codex exec`
# reports as a hard error. If doctor still says "config loaded / parse ok" it genuinely cannot
# distinguish the two states; if it flags it, the doc claim is wrong.
set -u
P="$1"
REAL="$P/.codex/config.toml"
BAK="$(mktemp)"; cp "$REAL" "$BAK"
trap 'cp "$BAK" "$REAL"; rm -f "$BAK"' EXIT

printf 'this is not = = valid toml [[[\n' > "$REAL"

echo "#### codex doctor, TRUSTED project, INVALID project config ####"
(cd "$P" && codex doctor 2>&1 | sed -n '/^Configuration/,/^  . auth/p')
echo
echo "#### any mention of the project config path anywhere in doctor output? ####"
(cd "$P" && codex doctor 2>&1 | grep -in "\.codex.config\|project config\|parse error" | head -10) || echo "  (no mention)"
echo
echo "#### for contrast, what codex exec says about the same state ####"
(cd "$P" && codex exec --sandbox read-only "reply with exactly: PONG" 2>&1 </dev/null | grep -iE "error|parse" | head -3)
