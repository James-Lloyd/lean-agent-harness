#!/usr/bin/env bash
# checkpoint.sh — git as the loop's undo button (bash mirror of checkpoint.ps1).
# Rollback is `git reset --hard` + `git clean -fd`, which discards UNCOMMITTED tree changes. Do not edit
# the tree while the loop runs; prefer a dedicated branch/worktree. The ref is persisted to
# harness/.checkpoint for crash visibility.
_CHECKPOINT_REF=""
# Default is the legacy shared path; the loop re-points this into its own run dir (set_checkpoint_file)
# so two concurrent runs can't overwrite each other's rollback ref. Crash visibility is preserved —
# the surviving ref sits in that run's harness/.runs/<runId>/ next to its logs and ledger.
_CHECKPOINT_FILE="$SCRIPT_DIR/.checkpoint"

set_checkpoint_file() { _CHECKPOINT_FILE="$1"; }

assert_clean_git_tree() {
  # rev-parse, not [ -d .git ]: in a git worktree .git is a FILE, and the header above explicitly
  # recommends running the loop in a worktree.
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "Not a git repo. The loop needs git for checkpoint/rollback. Run: git init"; exit 1; }
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Repo has no commits yet. Make an initial commit before starting the loop (rollback needs a HEAD)."; exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is dirty. Commit or stash before starting the loop."; exit 1
  fi
}

new_checkpoint() {  # $1 label
  _CHECKPOINT_REF="$(git rev-parse HEAD)"
  printf '%s' "$_CHECKPOINT_REF" > "$_CHECKPOINT_FILE" 2>/dev/null || true
  echo "  ⎘ checkpoint @ ${_CHECKPOINT_REF:0:8} ($1)"
}

restore_checkpoint() {
  local ref="$_CHECKPOINT_REF"
  [ -z "$ref" ] && [ -f "$_CHECKPOINT_FILE" ] && ref="$(cat "$_CHECKPOINT_FILE")"
  [ -z "$ref" ] && return 0
  git reset --hard "$ref" >/dev/null
  git clean -fd >/dev/null
  echo "  ↩ restored to ${ref:0:8}"
}

clear_checkpoint() { _CHECKPOINT_REF=""; rm -f "$_CHECKPOINT_FILE" 2>/dev/null || true; }

commit_iteration() {  # $1 index
  git add -A
  [ -z "$(git diff --cached --name-only)" ] && { echo "  (no changes to commit)"; return 0; }
  git commit -q -m "loop($1): green iteration

Automated by harness/loop. Gate passed.
Co-Authored-By: Claude <noreply@anthropic.com>"
  echo "  ✔ committed iteration $1"
}

tag_iteration() {  # $1 index  $2 runId(optional)
  local tag; if [ -n "${2:-}" ]; then tag="loop-$2-$1"; else tag="loop-$1"; fi
  git tag -f "$tag" >/dev/null; echo "  🏷 tagged $tag"
}
