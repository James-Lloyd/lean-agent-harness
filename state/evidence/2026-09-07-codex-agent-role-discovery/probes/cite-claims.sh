#!/usr/bin/env bash
# Round 4. Captures the artifacts behind two prose claims that the re-review flagged as
# uncited — including one added by the very commit that ratcheted against uncited claims:
#
#   K1  "`codex agents` is a session browser" (state/evidence/2026-09-06-codex-0153-reverify/
#       README.md). Asserted from a help screen nobody committed.
#   K2  "AgentRoleToml takes description, config_file and nickname_candidates"
#       (docs/codex-setup.md, README.md). Read out of the binary's string table, never saved.
#
# Both are FREE — help text and a binary string scan, no model call, no network.
set -uo pipefail
cd "$(dirname "$0")"

echo "=== codex: $(codex --version 2>&1)"
echo "=== date:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

echo "=== K1: codex agents --help (is it a session browser, or a way to run a role?)"
timeout 60 codex agents --help 2>&1 | sed -n '1,8p'
echo

echo "=== K2: the agent-role strings in the installed binary"
# Resolve the real executable behind the npm shim rather than hardcoding a version path.
bin="$(command -v codex || true)"
exe="$(find "$(dirname "$(dirname "$bin")")" -name 'codex.exe' -path '*bin*' 2>/dev/null | head -1)"
if [ -z "$exe" ]; then echo "(could not locate codex.exe under the npm prefix; K2 skipped)"; exit 0; fi
echo "--- executable: $(basename "$exe") ($(wc -c < "$exe") bytes)"
echo
echo "--- the AgentRoleToml struct's own field list, as the serde error text spells it:"
timeout 300 grep -a -o -E '.{0,60}struct AgentRoleToml with [0-9]+ elements' "$exe" | sort -u | head -5
echo
echo "--- the loader's validation messages (these are what the probes trip):"
timeout 300 grep -a -o -E '.{0,40}agent role file at.{0,60}' "$exe" | sort -u | head -10
echo
echo "--- config_file validation:"
timeout 300 grep -a -o -E '.{0,30}config_file must point.{0,40}' "$exe" | sort -u | head -5
echo
echo "=== round 4 complete."
