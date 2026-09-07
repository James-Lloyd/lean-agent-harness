#!/usr/bin/env bash
# Follow-on to role-discovery.sh. That script settled DISCOVERY (an undeclared
# `.codex/agents/*.toml` is read: arm B's malformed file produced
# "agent role file at ... must define `developer_instructions`" with nothing in
# config.toml referring to it). It did NOT settle VISIBILITY for the harness's own
# shape, because arm D's role was both well-formed AND declared.
#
# Arm E isolates that: a well-formed role file, present and UNDECLARED — exactly what
# `codex-setup` generates — and the session is asked to name the roles it can spawn.
# Arm F does the same against the REAL generated set, which is the clause the fix_plan
# item actually asks for ("one transcript shows a generated agent role in use").
#
# Same rules as the sibling script: `codex exec` is the oracle, not `codex doctor`;
# the project must be trusted; each arm is one real model call; never pipe this
# through `head`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
echo "=== project root: $ROOT"
echo "=== codex:       $(codex --version 2>&1)"
echo "=== date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

run() {
  if [ -n "${PROBE_SKIP_MODEL:-}" ]; then
    echo "--- codex exec [$1] SKIPPED (PROBE_SKIP_MODEL set - this is a real model call)"
    return 0
  fi
  echo "--- codex exec [$1]"
  timeout 300 codex exec --sandbox read-only -C "$ROOT" "$2" 2>&1
  echo "--- exit=$? [$1]"
  echo
}

LIST_PROMPT="Do not use any tools and do not read any files. List the names of the agent roles you can spawn, one name per line, nothing else. If you cannot spawn agents at all, reply NO-AGENTS."

# ---------------------------------------------- arm E: well-formed, UNDECLARED
rm -rf .codex
mkdir -p .codex/agents
cat > .codex/config.toml <<'TOML'
# no [agents] block - exactly what codex-setup generates
TOML
cat > .codex/agents/probeE.toml <<'TOML'
name = "probeE"
description = "probe E - well formed, present in .codex/agents, declared nowhere"
developer_instructions = """
You are a probe role. If asked to do anything, reply PROBE-E.
"""
TOML
echo "=== ARM E: well-formed role file, UNDECLARED (the shape codex-setup emits)"
run "E" "$LIST_PROMPT"

# ---------------------------------------------- arm F: the REAL generated set
# SUPERSEDED — do not re-run this arm expecting an answer. As written it omits HARNESS_ENGINE,
# so the wrapper falls through to the installed plugin cache and dies with "engine not found"
# before Codex is ever invoked. The working version is role-visible-real.sh.
# This arm HAS since been given the existence guard below, so it no longer matches
# results-visible.txt line for line: that transcript predates the guard and shows both the old
# fallback wording and the wasted model call that followed it. Script and transcript diverge on
# purpose — the transcript is the record of the failure, the script is what a re-run should do.
rm -rf .codex
echo "=== ARM F: generate the real .codex via the harness wrapper, then list roles"
bash harness/codex-setup.sh
# ASSERT BEFORE SPENDING. The original form was `grep … || echo "(none - confirms undeclared)"`,
# which prints the reassuring line when the file is MISSING, because grep's "No such file" also
# exits non-zero. It did exactly that below, and the script then paid for a model call that could
# not answer anything. A control that speaks when nothing happened is worse than no control.
if [ ! -f .codex/config.toml ]; then
  echo "FAIL: the generator produced no .codex/config.toml - not spending a model call"
  exit 1
fi
echo "--- generated agent role files:"
ls .codex/agents/
echo "--- [agents] blocks in the generated config.toml (expected: none):"
grep -n "^\[agents" .codex/config.toml || echo "(none present in a file that EXISTS - roles are undeclared)"
echo
run "F" "$LIST_PROMPT"

echo "=== probe complete. .codex/ holds the REAL generated set; it is gitignored."
