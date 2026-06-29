#!/usr/bin/env bash
# SessionStart hook — orient a fresh context fast (bash mirror of session-start.ps1).
# stdout is injected into the session as context. Keep it short.
cat >/dev/null
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
lines=()

branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$branch" ] && lines+=("branch: $branch")

plan="$root/state/fix_plan.md"
if [ -f "$plan" ]; then
  open=$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$plan" || echo 0)
  lines+=("open tasks: $open")
  if [ "$open" -gt 0 ]; then
    next="$(grep -E '^[[:space:]]*[-*][[:space:]]+\[ \]' "$plan" | head -1 | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*//')"
    lines+=("next up: $next")
  fi
fi

progress="$root/state/PROGRESS.md"
if [ -f "$progress" ]; then
  last="$(grep -v '^[[:space:]]*$' "$progress" | tail -1 || true)"
  [ -n "$last" ] && lines+=("last progress: $last")
fi

handoff="$root/state/handoff.md"
if [ -f "$handoff" ] && grep -q 'Needs human decision' "$handoff"; then
  lines+=("⚠ handoff.md has an unresolved 'Needs human decision' — read it before working.")
fi

if [ "${#lines[@]}" -gt 0 ]; then
  echo "Harness state ::"
  for l in "${lines[@]}"; do echo "  - $l"; done
  echo "Read CLAUDE.md for the map. One task per iteration; verify before done."
fi
exit 0
