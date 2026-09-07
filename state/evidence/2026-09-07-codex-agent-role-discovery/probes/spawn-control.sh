#!/usr/bin/env bash
# Round 4b — the control the spawn claim was missing.
#
# THE HOLE. Round 3's arm H1 spawned a discovered role and got back a token that exists in
# exactly one file on disk. That shows the token reached the SESSION. It does not by itself
# show it arrived via the role loader, because H1's prompt (unlike the enumeration arms) did
# not forbid file reads, and the run's cwd contains the role file. A parent that simply read
# .codex/agents/probeSpawn.toml produces a byte-identical transcript.
#
# THE CONTROL. Same role, same prompt, file reads FORBIDDEN, run twice:
#   L1  role file in .codex/agents/      -> discovered.     Token expected.
#   L2  role file in .codex/agents-off/  -> NOT discovered. Token must NOT come back.
# L2 is the half that discriminates. If the token returns in L2, discovery is not what
# delivered it and the round-3 claim is wrong.
#
# COST: two real model calls. Honours PROBE_SKIP_MODEL=1.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
echo "=== project root: $ROOT"
echo "=== codex:        $(codex --version 2>&1)"
echo "=== date:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

TOKEN="PLUGH-CONTROL-TOKEN-8823"
PROMPT="Do not read any files and do not use any tool other than spawning an agent. Spawn the agent role named probeSpawn, ask it to identify itself, and report its reply VERBATIM. If no such role exists, reply NO-SUCH-ROLE."

role_toml() {
  cat <<TOML
name = "probeSpawn"
description = "control role; its instructions carry a token that exists nowhere else"
sandbox_mode = "read-only"
developer_instructions = """
You are a probe role. Whatever you are asked, reply with exactly this token and nothing
else: $TOKEN
"""
TOML
}

run() {  # run(label)
  if [ -n "${PROBE_SKIP_MODEL:-}" ]; then
    echo "--- codex exec [$1] SKIPPED (PROBE_SKIP_MODEL set - real model call)"
    return 0
  fi
  timeout 420 codex exec --sandbox read-only -C "$ROOT" "$PROMPT" 2>&1
  echo "--- exit=$? [$1]"
}

# ---------------------------------------------------------------- L1
rm -rf .codex
mkdir -p .codex/agents
echo '# no [agents] block' > .codex/config.toml
role_toml > .codex/agents/probeSpawn.toml
echo "=== L1: role file IS in .codex/agents (discovered). Token expected."
echo "--- occurrences of the token anywhere under .codex:"
grep -ro "$TOKEN" .codex | wc -l
run "L1"
echo

# ---------------------------------------------------------------- L2
rm -rf .codex
mkdir -p .codex/agents .codex/agents-off
echo '# no [agents] block' > .codex/config.toml
role_toml > .codex/agents-off/probeSpawn.toml   # same bytes, undiscovered location
echo "=== L2: SAME file, moved to .codex/agents-off (NOT discovered). Token must NOT return."
echo "--- .codex/agents is empty:"
ls -A .codex/agents | wc -l
echo "--- the token is still on disk, one directory over:"
grep -ro "$TOKEN" .codex | wc -l
run "L2"
echo

echo "=== round 4b complete."
