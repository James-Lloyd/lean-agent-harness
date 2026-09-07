#!/usr/bin/env bash
# Proof that scrub-paths.sh actually substitutes, not merely reports "scrubbed".
#
# WHY THIS EXISTS. The first version of scrub-paths.sh carried the home path as a literal,
# which made the script itself unstageable under the repo's privacy guard. The rewrite derives
# the patterns from $HOME and the repo name at runtime — and by then the three results files
# were already clean, so the rewrite printed "scrubbed" three times having changed nothing.
# A tool that silently does nothing looks exactly like a tool that works. This forces it.
#
# Method: plant a dirty copy under the names scrub-paths.sh operates on, in a temp dir that
# is a sibling of nothing, run the scrubber there, and assert the guard's own pattern is gone.
set -euo pipefail
cd "$(dirname "$0")"

work="$(mktemp -d)"
trap 'rm -f "$work"/*.txt "$work"/*.sh 2>/dev/null; rmdir "$work" 2>/dev/null || true' EXIT
cp scrub-paths.sh "$work/"

user="$(basename "$HOME")"
top="$(git rev-parse --show-toplevel)"
repo="$(basename "$top")"
case "$top" in *".claude/worktrees/"*) repo="$(basename "${top%%/.claude/worktrees/*}")";; esac

# A dirty fixture in both slash styles and both cases, as the real transcripts carry them.
{
  printf 'project root: /c/Users/%s/Repos/%s/.claude/worktrees/x\n' "$user" "$repo"
  printf 'workdir: C:\\Users\\%s\\Repos\\%s\\.claude\n' "$user" "$repo"
  printf "trust: [projects.'c:\\\\users\\\\%s\\\\repos\\\\%s']\\n" "$user" "$repo"
} > "$work/results-raw.txt"

echo "--- fixture before:"
cat "$work/results-raw.txt"

( cd "$work" && HARNESS_SCRUB_USER="$user" HARNESS_SCRUB_REPO="$repo" bash scrub-paths.sh )

echo "--- fixture after:"
cat "$work/results-raw.txt"

# The assertion is the repo's own guard pattern, not a restatement of the sed script.
if grep -naiE "[Uu]sers[/\\\\]$user" "$work/results-raw.txt"; then
  echo "FAIL: a home path survived the scrub"
  exit 1
fi
if ! grep -q '<you>' "$work/results-raw.txt"; then
  echo "FAIL: nothing was substituted (the scrubber is a no-op)"
  exit 1
fi
echo "PASS: home paths removed and replaced with <you>/<repo>"
