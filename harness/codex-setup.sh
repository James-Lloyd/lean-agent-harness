#!/usr/bin/env bash
# Thin wrapper - dispatches to the lean-agent-harness plugin ENGINE's codex-setup.sh, passing THIS repo as
# --project-root. Generated into <project>/harness/codex-setup.sh by /harness-init. The generator ships in
# the installed plugin; this shim only locates it so `bash harness/codex-setup.sh` works from a bare
# terminal (where $CLAUDE_PLUGIN_ROOT is unset). Override with $HARNESS_ENGINE. Re-run after every
# `/plugin update lean-agent-harness` and after any routing change (the output embeds the plugin path).
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_engine() {
  if [ -n "${HARNESS_ENGINE:-}" ] && [ -f "$HARNESS_ENGINE/codex-setup.sh" ]; then echo "$HARNESS_ENGINE"; return; fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/engine/codex-setup.sh" ]; then echo "$CLAUDE_PLUGIN_ROOT/engine"; return; fi
  local base="$HOME/.claude/plugins" hit
  if [ -d "$base" ]; then
    # Newest by mtime (a /plugin update keeps the old version ~7 days); GNU stat -c || BSD stat -f.
    hit="$(find "$base" -type f -name codex-setup.sh -path '*lean-agent-harness*/engine/codex-setup.sh' 2>/dev/null \
      | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" "$f"; done \
      | sort -rn | head -1 | cut -f2-)"
    if [ -n "$hit" ]; then dirname "$hit"; return; fi
  fi
  echo "lean-agent-harness engine not found. Install the plugin (/plugin install lean-agent-harness) or set \$HARNESS_ENGINE to its engine/ dir." >&2
  exit 1
}

ENGINE="$(find_engine)"
exec bash "$ENGINE/codex-setup.sh" --project-root "$PROJECT_ROOT" "$@"
