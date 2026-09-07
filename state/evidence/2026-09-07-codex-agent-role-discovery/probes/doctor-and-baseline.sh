#!/usr/bin/env bash
# Round 2, opened by the fresh-context review. Three claims in round 1 were stated as
# measured with no committed artifact behind them, which is a class this repo has already
# ratcheted once. This script produces the artifacts.
#
#   G1  `codex doctor` is silent about a broken role that `codex exec` warns about.
#       Round 1 asserted this in six surfaces citing "run 1", whose output was never
#       committed — and attributed it to the DECLARED-missing-file role, while the prose
#       attributed it to the DISCOVERED-malformed one. Different claims. G1 runs doctor
#       under the malformed-and-undeclared state, which is the one the finding rests on.
#   G2  `CODEX_HOME` redirects the whole user-level layer. Quoted verbatim in round 1
#       ("no Codex credentials were found", "Refusing to create helper binaries under
#       temporary dir", "all five SQLite DBs") from an uncommitted terminal run.
#   G3  Which role names are BUILT IN. Round 1 wrote "beside the built-in default and
#       worker", but arm E listed `explorer` with no explorer.toml on disk, and the failed
#       arm F (no .codex at all) answered `general-purpose`. Those cannot both be a stable
#       built-in set, so the model may be confabulating names. G3 asks the same question
#       twice against an EMPTY project layer to see whether the answer is even stable.
#
# COST: G1 and G2 are `codex doctor` only — no model call, free. G3 is two real calls.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
echo "=== project root: $ROOT"
echo "=== codex:        $(codex --version 2>&1)"
echo "=== date:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# ---------------------------------------------------------------- G1
rm -rf .codex
mkdir -p .codex/agents
cat > .codex/config.toml <<'TOML'
# no [agents] block - exactly what codex-setup generates
TOML
cat > .codex/agents/probeB.toml <<'TOML'
name = "probeB"
description = "probe B - present in .codex/agents, declared nowhere, and MALFORMED"
TOML
echo "=== G1: does 'codex doctor' report the malformed UNDECLARED role that 'codex exec' warned about?"
echo "--- state on disk:"
ls .codex/agents/
cat .codex/config.toml
echo "--- codex doctor (full Notes + Configuration sections, unfiltered head):"
timeout 120 codex doctor 2>&1 | sed -n '1,20p'
echo "--- grep the FULL doctor output for any mention of the role (this is the assertion):"
# CAPTURE FIRST, THEN ASSERT — `codex doctor` can exit non-zero, and under `set -o pipefail`
# that status wins over a MATCHING grep, firing the `||` fallback on a successful match.
# And grep the WHOLE output: the round-1 claim that doctor is silent came from reading only
# the first 30 lines. The warning is at line 121.
g1_out="$(timeout 120 codex doctor 2>&1 || true)"
if printf '%s\n' "$g1_out" | grep -niE "probeB|agent role|malformed agent|developer_instructions"; then
  echo "(MATCHED - doctor DOES report it)"
else
  echo "(NO MENTION - doctor is silent about it)"
fi
echo

# ---------------------------------------------------------------- G2
home_probe="$ROOT/.codex-home-probe"     # deliberately NOT under the system temp dir
rm -rf "$home_probe"; mkdir -p "$home_probe"
echo "=== G2: does CODEX_HOME redirect the user-level layer?"
echo "--- codex doctor with CODEX_HOME=$home_probe :"
g2_out="$(CODEX_HOME="$home_probe" timeout 120 codex doctor 2>&1 || true)"
if printf '%s\n' "$g2_out" | grep -niE "codex_home|refusing|credential|auth|sqlite|log dir|state DB|goals DB|memories DB|queue DB|thread history DB"; then
  echo "(MATCHED)"
else
  echo "(no matching lines)"
fi
echo "--- count of user-level SQLite DBs reported under the new home:"
printf '%s\n' "$g2_out" | grep -c "codex-home-probe.*sqlite" || true
rm -rf "$home_probe"
echo

# ---------------------------------------------------------------- G3
rm -rf .codex
echo "=== G3: baseline role list with NO project .codex at all, asked TWICE"
LIST_PROMPT="Do not use any tools and do not read any files. List the names of the agent roles you can spawn, one name per line, nothing else. If you cannot spawn agents at all, reply NO-AGENTS."
if [ -n "${PROBE_SKIP_MODEL:-}" ]; then echo "(skipped: PROBE_SKIP_MODEL set - these two arms are real model calls)"; else
echo "--- run 1:"
timeout 300 codex exec --sandbox read-only -C "$ROOT" "$LIST_PROMPT" 2>&1
echo "--- run 2 (same prompt, same empty state - is the answer stable?):"
timeout 300 codex exec --sandbox read-only -C "$ROOT" "$LIST_PROMPT" 2>&1
fi
echo

echo "=== round 2 complete."
