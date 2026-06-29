#!/usr/bin/env bash
# PostToolUse(Edit|Write) hook — run the FAST half of the gate (bash mirror of format-and-check.ps1).
# Silent on success; on failure exit 2 with the error on stderr so the fix lands in the model context.
cat >/dev/null   # consume stdin payload; we act on config for stack-neutrality
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
config="$root/harness/harness.config.json"
[ -f "$config" ] || exit 0
command -v jq >/dev/null || exit 0

failed=0; report=""
for name in format lint typecheck; do
  cmd="$(jq -r ".gate.$name // empty" "$config")"
  [ -z "$cmd" ] || [ "$cmd" = "null" ] && continue
  if ! out="$(cd "$root" && bash -lc "$cmd" 2>&1)"; then
    failed=1
    report+=$'\n'"✗ $name failed: $cmd"$'\n'"$(printf '%s' "$out" | tail -n 25 | sed 's/^/   /')"
  fi
done

if [ "$failed" -eq 1 ]; then
  echo "Harness gate (fast) found problems in the change you just made. Fix them before continuing:" >&2
  echo "$report" >&2
  exit 2
fi
exit 0
