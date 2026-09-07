#!/usr/bin/env bash
# Arm F, re-run. The first attempt failed before it reached Codex at all:
#
#   lean-agent-harness engine not found. Install the plugin (/plugin install
#   lean-agent-harness) or set $HARNESS_ENGINE to its engine/ dir.
#
# That is the HYBRID load path recorded at the E2 flip: nothing auto-sets
# HARNESS_ENGINE for a bare wrapper call, so it falls through to the installed
# ~/.claude/plugins cache — which on this machine is 0.2.9 (2026-08-12) and predates
# codex-setup entirely. Point it at the live in-repo engine, as the suites do.
#
# The question this arm answers is the fix_plan clause: does a role file that the
# harness ACTUALLY GENERATES reach a real Codex session by name?
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
export HARNESS_ENGINE="$ROOT/plugin/engine"
echo "=== project root:    $ROOT"
echo "=== HARNESS_ENGINE:  $HARNESS_ENGINE"
echo "=== codex:           $(codex --version 2>&1)"
echo "=== date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

rm -rf .codex
echo "=== generate the real .codex via the harness wrapper"
bash harness/codex-setup.sh
echo
# ASSERT BEFORE SPENDING — `grep … || echo "(none)"` also fires when the file is MISSING, since
# grep's "No such file" exits non-zero too. In role-visible.sh that printed a reassuring line over
# a generator that had failed, and the script went on to pay for a useless model call.
if [ ! -f .codex/config.toml ] || [ ! -d .codex/agents ]; then
  echo "FAIL: the generator produced no .codex - not spending a model call"
  exit 1
fi
echo "--- generated agent role files:"
ls .codex/agents/
echo
echo "--- [agents] blocks in the generated config.toml (expected: none):"
grep -n "^\[agents" .codex/config.toml || echo "(none present in a file that EXISTS - roles are UNDECLARED)"
echo
echo "--- head of one generated role file:"
head -8 .codex/agents/reviewer.toml
echo

echo "=== codex exec [F]"
if [ -n "${PROBE_SKIP_MODEL:-}" ]; then
  echo "SKIPPED (PROBE_SKIP_MODEL set - this is a real model call)"
else
  timeout 300 codex exec --sandbox read-only -C "$ROOT" \
    "Do not use any tools and do not read any files. List the names of the agent roles you can spawn, one name per line, nothing else. If you cannot spawn agents at all, reply NO-AGENTS." 2>&1
  echo "--- exit=$? [F]"
fi
echo "=== probe complete. .codex/ holds the REAL generated set; it is gitignored."
