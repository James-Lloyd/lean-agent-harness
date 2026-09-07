#!/usr/bin/env bash
# Normalize machine-local home paths in the captured probe output before staging.
#
# This repo is PUBLIC and its .git/hooks/pre-commit blocks any staged content carrying a
# home-directory path — agent-captured logs are full of them (the 2026-08-08 scrub).
# Convention, matching state/evidence/2026-09-06-codex-0153-reverify/results.txt:
#   <home>\repos\<this repo>  ->  \users\<you>\repos\<repo>   (either slash, either case)
#
# The patterns are DERIVED from $HOME and the repo path at runtime rather than written out,
# because a scrub script containing the literal it scrubs for is itself unstageable — the
# guard reads staged CONTENT, and does not care that the file is the fix.
# Idempotent: re-running it changes nothing.
set -euo pipefail
cd "$(dirname "$0")"

# Both values may be overridden, which is how scrub-proof.sh drives a copy of this script
# from a temp dir where neither can be derived correctly.
user="${HARNESS_SCRUB_USER:-$(basename "$HOME")}"   # the OS username, as it appears in a home path

# The repo name is derived from THIS SCRIPT's own location (probes/ is four levels under the
# checkout root), never from `git rev-parse`: the scrubber must run anywhere, including on a
# copy in a temp dir, which is how scrub-proof.sh exercises it. The git version died there
# with "fatal: not a git repository" — caught by that proof, not by review.
top="$(cd "$(dirname "$0")/../../../.." && pwd)"
repo="$(basename "$top")"
# A worktree lives at <repo>/.claude/worktrees/<name>, so walk up to the real repo name.
case "$top" in *".claude/worktrees/"*) repo="$(basename "${top%%/.claude/worktrees/*}")";; esac
repo="${HARNESS_SCRUB_REPO:-$repo}"

for f in results-raw.txt results-visible.txt results-visible-real.txt; do
  [ -f "$f" ] || continue
  sed -i \
    -e "s|[Uu]sers/$user/[Rr]epos/$repo|Users/<you>/Repos/<repo>|g" \
    -e "s|users\\\\$user\\\\repos\\\\$repo|users\\\\<you>\\\\repos\\\\<repo>|g" \
    -e "s|[Uu]sers\\\\$user\\\\[Rr]epos\\\\$repo|Users\\\\<you>\\\\Repos\\\\<repo>|g" \
    -e "s|[Uu]sers/$user|Users/<you>|g" \
    -e "s|[Uu]sers\\\\$user|Users\\\\<you>|g" \
    "$f"
  echo "scrubbed $f"
done
