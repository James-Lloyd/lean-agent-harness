#!/usr/bin/env bash
# Thin wrapper — dispatches to the lean-agent-harness plugin ENGINE (fleet runner), passing THIS repo as
# --project-root. Generated into <project>/harness/fleet.sh by /harness-init. See harness/loop.sh in this
# project for the engine-discovery contract; upgrade with `/plugin update lean-agent-harness`.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_engine() {
  if [ -n "${HARNESS_ENGINE:-}" ] && [ -f "$HARNESS_ENGINE/fleet.sh" ]; then echo "$HARNESS_ENGINE"; return; fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/engine/fleet.sh" ]; then echo "$CLAUDE_PLUGIN_ROOT/engine"; return; fi
  local base="$HOME/.claude/plugins" hit
  if [ -d "$base" ]; then
    # Newest by mtime, not filesystem-traversal order (see loop.sh wrapper). stat -c (GNU) || -f (BSD).
    hit="$(find "$base" -type f -name fleet.sh -path '*lean-agent-harness*/engine/fleet.sh' 2>/dev/null \
      | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" "$f"; done \
      | sort -rn | head -1 | cut -f2-)"
    if [ -n "$hit" ]; then dirname "$hit"; return; fi
  fi
  echo "lean-agent-harness engine not found. Install the plugin (/plugin install lean-agent-harness) or set \$HARNESS_ENGINE to its engine/ dir." >&2
  exit 1
}

ENGINE="$(find_engine)"
exec bash "$ENGINE/fleet.sh" --project-root "$PROJECT_ROOT" "$@"
