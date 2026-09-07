#!/usr/bin/env bash
# Codex CLI 0.153.4 — is `.codex/agents/*.toml` auto-discovered, or must config.toml
# declare each role with `config_file`?
#
# ORACLE. The agent-role loader carries its own strings in the binary:
#   "Ignoring malformed agent role definition: ..."
#   "<name>.config_file must point to an existing file at <path>"
#   "agent role file at <path> must define `developer_instructions`"
# A DELIBERATELY MALFORMED role file therefore discriminates: if the loader reads the
# file we see one of those lines; if the file is never discovered we see silence.
# Silence only means something beside a POSITIVE CONTROL that proves the oracle fires
# in this exact environment — arms A and C are those controls.
#
# USE `codex exec` AS THE ORACLE. An earlier version of this comment claimed doctor is
# blind to a broken role, citing an uncommitted run. That was WRONG, and the fresh-context
# review was right to refuse it: doctor DOES carry the same text, as a `startup warning`
# field deep in its Configuration section — see doctor-and-baseline.sh arm G1 and line 121
# of results-round2.txt. The false claim came from reading only doctor's first 30 lines.
# `codex exec` is preferred here because it puts the warning near the top of a short
# transcript, not because doctor cannot see it.
#
# TRUST. An untrusted project silently skips its whole .codex/ layer, so every arm
# would read as "not discovered" for the wrong reason. `[projects.'c:\users\<you>\
# repos\<repo>']` is trusted and trust is prefix-based, so this worktree inherits it.
# Arm 0 asserts it; do not interpret any other arm without it.
#
# COST. Each arm is one real `codex exec` model call (~13k tokens on run 1). Four
# calls. Do not run this in a loop.
#
# DO NOT pipe this script's stdout through `head` — that is how run 1 died: head
# closed the pipe at line 120, tee took SIGPIPE and the script went with it, losing
# arms C and D. Redirect to a file and read the file.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"   # the worktree root
cd "$ROOT" || exit 1
echo "=== project root: $ROOT"
echo "=== codex:       $(codex --version 2>&1)"
echo "=== date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

run() {  # run(label, prompt)
  echo "--- codex exec [$1]"
  timeout 300 codex exec --sandbox read-only -C "$ROOT" "$2" 2>&1
  echo "--- exit=$? [$1]"
  echo
}

mkdir -p .codex/agents

# ---------------------------------------------------------------- arm 0: trust
echo "=== ARM 0: trust entry for this prefix (without it every later arm is void)"
# Derived, not hardcoded: an earlier version grepped for this repo's own name, so the arm
# silently reported NO TRUST ENTRY in any other checkout. Trust is prefix-based, so the entry
# that matters is the one covering the repo root, whatever it is called.
repo_name="$(basename "$(cd "$ROOT" && git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")")"
case "$ROOT" in *".claude/worktrees/"*) repo_name="$(basename "${ROOT%%/.claude/worktrees/*}")";; esac
trust_out="$(grep -n -i -A1 "repos.${repo_name}'\]" "$HOME/.codex/config.toml" 2>/dev/null || true)"
if [ -n "$trust_out" ]; then
  printf '%s\n' "$trust_out"
else
  echo "NO TRUST ENTRY for '$repo_name' - every later arm is VOID, stop here"
fi
echo

# ------------------------------------------------- arm A: positive control
# A role DECLARED in config.toml whose config_file does not exist. If the project
# config layer is read at all, the loader must complain about the missing file.
rm -f .codex/agents/*.toml
cat > .codex/config.toml <<'TOML'
[agents.probeA]
description = "probe A - declared, file missing"
config_file = "agents/does-not-exist.toml"
TOML
echo "=== ARM A: declared role, config_file points at a missing file (POSITIVE CONTROL)"
run "A" "reply with the single word OK"

# ------------------------------------------------- arm B: the real-world shape
# The harness generator writes .codex/agents/<name>.toml and NO [agents] block.
# Put a MALFORMED role file there (no developer_instructions) with nothing declaring
# it. A warning => the directory is auto-discovered. Silence => it is not.
cat > .codex/config.toml <<'TOML'
# no [agents] block - exactly what codex-setup generates
TOML
cat > .codex/agents/probeB.toml <<'TOML'
name = "probeB"
description = "probe B - present in .codex/agents, declared nowhere, and MALFORMED"
TOML
echo "=== ARM B: malformed role file in .codex/agents, undeclared (THE QUESTION)"
run "B" "reply with the single word OK"

# ------------------------------------------------- arm C: declared + malformed
# The SAME malformed file, now DECLARED. Proves the malformed-FILE oracle fires, so
# arm B's silence cannot be blamed on the content being tolerated rather than unread.
cat > .codex/config.toml <<'TOML'
[agents.probeB]
description = "probe C - declared and malformed"
config_file = "agents/probeB.toml"
TOML
echo "=== ARM C: the SAME malformed role file, now declared (ORACLE CONTROL)"
run "C" "reply with the single word OK"

# ------------------------------------------------- arm D: well-formed + declared
# The shape codex-setup emits, declared. Clean load => the generated FILES are fine
# and only the DECLARATION is missing. The prompt also asks the model to name its
# roles, which is the only way to see the role reach the session.
cat > .codex/agents/probeD.toml <<'TOML'
name = "probeD"
description = "probe D - well formed"
developer_instructions = """
You are a probe. Reply with the single word PROBE-D.
"""
TOML
cat > .codex/config.toml <<'TOML'
[agents.probeD]
description = "probe D - declared and well formed"
config_file = "agents/probeD.toml"
TOML
echo "=== ARM D: well-formed role file, declared (does it load clean, and is it visible?)"
run "D" "Do not use any tools. List the names of the agent roles you can spawn, one per line. If you cannot spawn agents, say NO-AGENTS."

echo "=== probe complete. .codex/ is left in place for inspection; it is gitignored."
