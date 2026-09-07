#!/usr/bin/env bash
# Round 3. Two gaps left by round 2, both raised by the fresh-context review.
#
#   H1  SPAWN. Round 1 claimed a discovered role is "spawnable" and that arm F satisfied
#       the fix_plan clause "one transcript shows a generated agent role IN USE". Neither
#       was measured: every arm only asked the model to NAME roles, and an enumeration is
#       not use. H1 spawns a discovered role whose developer_instructions carry a unique
#       token, and looks for that token coming back. The token is the assertion — a name
#       can be confabulated (round 2 proved the model invents plausible role names), a
#       string that exists only inside the role file cannot be.
#   H2  The "Refusing to create helper binaries under temporary dir" quote. Round 2's
#       CODEX_HOME probe deliberately used a home OUTSIDE the system temp dir, so it could
#       not reproduce the refusal it quotes. H2 puts a throwaway home under the system temp
#       dir on purpose. `codex doctor` only — free.
#
# COST: H1 is one real model call (it also spawns a sub-agent, so it may cost more than a
# one-liner). H2 is free.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
echo "=== project root: $ROOT"
echo "=== codex:        $(codex --version 2>&1)"
echo "=== date:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# ---------------------------------------------------------------- H1
rm -rf .codex
mkdir -p .codex/agents
cat > .codex/config.toml <<'TOML'
# no [agents] block - exactly what codex-setup generates
TOML
cat > .codex/agents/probeSpawn.toml <<'TOML'
name = "probeSpawn"
description = "probe role whose instructions carry a token that exists nowhere else"
sandbox_mode = "read-only"
developer_instructions = """
You are a probe role. Whatever you are asked, reply with exactly this token and nothing
else: XYZZY-ROLE-TOKEN-4417
"""
TOML
echo "=== H1: spawn a DISCOVERED role and look for a token that lives only in its instructions"
if [ -n "${PROBE_SKIP_MODEL:-}" ]; then echo "(skipped: PROBE_SKIP_MODEL set - this arm is a real model call)"; else
echo "--- state on disk (no [agents] block, one role file):"
ls .codex/agents/
echo "--- files under .codex containing the token (expected: 1):"
grep -rl "XYZZY-ROLE-TOKEN-4417" .codex | wc -l   # was `grep -rc <one named file>`, which
                                                  # counts LINES in a file it was handed, and
                                                  # so could not have detected a second copy
echo
timeout 420 codex exec --sandbox read-only -C "$ROOT" \
  "Spawn the agent role named probeSpawn, ask it to identify itself, and report its reply VERBATIM. If you cannot spawn it, reply CANNOT-SPAWN and say why." 2>&1
echo "--- exit=$? [H1]"
fi
echo

# ---------------------------------------------------------------- H2
tmp_home="${TMPDIR:-/tmp}/codex-home-tempdir-probe"
rm -rf "$tmp_home"; mkdir -p "$tmp_home"
echo "=== H2: CODEX_HOME UNDER the system temp dir - does Codex refuse to place helpers?"
echo "--- CODEX_HOME=$tmp_home"
# CAPTURE FIRST, THEN ASSERT. Piping straight into `grep … || echo "(none)"` is wrong here:
# `codex doctor` exits non-zero on the missing-auth check, and under `set -o pipefail` that
# failure becomes the pipeline's status, so the `||` fallback fires even when grep MATCHED.
# The first version of this line printed the matching refusal AND "(no refusal line)" under
# it. Same shape as the review's S4 finding, reproduced here by hand one round later.
h2_out="$(CODEX_HOME="$tmp_home" timeout 120 codex doctor 2>&1 || true)"
if printf '%s\n' "$h2_out" | grep -niE "refusing|helper binaries|temporary dir|PATH aliases"; then
  echo "(MATCHED - the refusal reproduces)"
else
  echo "(no refusal line - the round-1 quote does NOT reproduce)"
fi
rm -rf "$tmp_home"
echo
echo "=== round 3 complete."
