#!/usr/bin/env bash
# Thin wrapper — dispatches to the lean-agent-harness plugin ENGINE, passing THIS repo as --project-root.
# Generated into <project>/harness/loop.sh by /harness-init. The real loop ships in the installed plugin;
# this shim only locates it so `bash harness/loop.sh ...` works from a bare terminal or cron (where
# $CLAUDE_PLUGIN_ROOT is unset). Override with $HARNESS_ENGINE. Upgrade: /plugin update lean-agent-harness.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_engine() {
  if [ -n "${HARNESS_ENGINE:-}" ] && [ -f "$HARNESS_ENGINE/loop.sh" ]; then echo "$HARNESS_ENGINE"; return; fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/engine/loop.sh" ]; then echo "$CLAUDE_PLUGIN_ROOT/engine"; return; fi
  local base="$HOME/.claude/plugins" hit
  if [ -d "$base" ]; then
    # Newest by mtime, not filesystem-traversal order: `/plugin update` keeps the old version ~7 days,
    # so head -1 could dispatch a stale engine. stat -c (GNU) || stat -f (BSD/macOS) for portability.
    hit="$(find "$base" -type f -name loop.sh -path '*lean-agent-harness*/engine/loop.sh' 2>/dev/null \
      | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" "$f"; done \
      | sort -rn | head -1 | cut -f2-)"
    if [ -n "$hit" ]; then dirname "$hit"; return; fi
  fi
  echo "lean-agent-harness engine not found. Install the plugin (/plugin install lean-agent-harness) or set \$HARNESS_ENGINE to its engine/ dir." >&2
  exit 1
}

ENGINE="$(find_engine)"
exec bash "$ENGINE/loop.sh" --project-root "$PROJECT_ROOT" "$@"
