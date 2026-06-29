#!/usr/bin/env bash
# checkpoint.sh — git as the loop's undo button (bash mirror of checkpoint.ps1).
_CHECKPOINT_REF=""

assert_clean_git_tree() {
  [ -d "$REPO_ROOT/.git" ] || { echo "Not a git repo. The loop needs git for checkpoint/rollback. Run: git init"; exit 1; }
  if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is dirty. Commit or stash before starting the loop."; exit 1
  fi
}

new_checkpoint() {  # $1 label
  _CHECKPOINT_REF="$(git rev-parse HEAD)"
  echo "  ⎘ checkpoint @ ${_CHECKPOINT_REF:0:8} ($1)"
}

restore_checkpoint() {
  [ -z "$_CHECKPOINT_REF" ] && return 0
  git reset --hard "$_CHECKPOINT_REF" >/dev/null
  git clean -fd >/dev/null
  echo "  ↩ restored to ${_CHECKPOINT_REF:0:8}"
}

clear_checkpoint() { _CHECKPOINT_REF=""; }

commit_iteration() {  # $1 index
  git add -A
  [ -z "$(git diff --cached --name-only)" ] && { echo "  (no changes to commit)"; return 0; }
  git commit -q -m "loop($1): green iteration

Automated by harness/loop. Gate passed.
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  echo "  ✔ committed iteration $1"
}

tag_iteration() { git tag -f "loop-$1" >/dev/null; echo "  🏷 tagged loop-$1"; }
