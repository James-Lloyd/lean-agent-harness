#!/usr/bin/env bash
# PostToolUse(Edit|Write) hook — run the FAST half of the gate for the COMPONENT owning the changed file
# (bash mirror of format-and-check.ps1). Routes a changed file to the component whose `path` is its
# deepest prefix and runs format+lint+typecheck there. Silent on success; exit 2 + stderr on failure.
root="${CLAUDE_PROJECT_DIR:-$(pwd)}"; root="${root%/}"
payload="$(cat)"
config="$root/harness/harness.config.json"
[ -f "$config" ] || exit 0
command -v jq >/dev/null || exit 0

changed="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
# repo-relative, forward-slash
rel=""
if [ -n "$changed" ]; then
  case "$changed" in
    "$root"/*) rel="${changed#"$root"/}";;
    /*) rel="$changed";;
    *) rel="$changed";;
  esac
fi

n="$(jq -r '.components | length' "$config" 2>/dev/null || echo 0)"
{ [ "$n" = "0" ] || [ "$n" = "null" ]; } && exit 0

# choose target component index by deepest path prefix; -1 => check all
# nocasematch so routing matches the .ps1 (case-insensitive) on case-insensitive filesystems.
shopt -s nocasematch
target=-1; bestlen=-1
i=0
while [ "$i" -lt "$n" ]; do
  p="$(jq -r ".components[$i].path" "$config")"; p="${p%/}"
  if [ -n "$rel" ]; then
    if [ "$p" = "." ] || [ "$p" = "" ]; then
      [ 0 -gt "$bestlen" ] && { bestlen=0; target=$i; }
    else
      case "$rel/" in "$p"/*) len=${#p}; [ "$len" -gt "$bestlen" ] && { bestlen=$len; target=$i; };; esac
    fi
  fi
  i=$((i+1))
done

run_fast_for() {  # $1 component index
  local idx="$1" cname cpath name cmd out code=0
  cname="$(jq -r ".components[$idx].name" "$config")"
  cpath="$(jq -r ".components[$idx].path" "$config")"
  [ -d "$root/$cpath" ] || return 0
  for name in format lint typecheck; do
    cmd="$(jq -r ".components[$idx].gate.$name // empty" "$config")"
    { [ -z "$cmd" ] || [ "$cmd" = "null" ]; } && continue
    if ! out="$(cd "$root/$cpath" && bash -lc "$cmd" 2>&1)"; then
      FAILED=1
      REPORT+=$'\n'"[$cname] x $name failed: $cmd"$'\n'"$(printf '%s' "$out" | tail -n 25 | sed 's/^/   /')"
    fi
  done
}

FAILED=0; REPORT=""
if [ "$target" -ge 0 ]; then
  run_fast_for "$target"
elif [ -n "$rel" ]; then
  # Known file owned by NO component (e.g. state/PROGRESS.md in a repo with no '.'-path component):
  # silently skip — running every component's gate per progress-log append is a heavy per-edit tax and
  # `prettier --write .` style formatters would mutate files as a side effect of unrelated edits.
  exit 0
else
  i=0; while [ "$i" -lt "$n" ]; do run_fast_for "$i"; i=$((i+1)); done   # file UNKNOWN -> check all (safe)
fi

if [ "$FAILED" -eq 1 ]; then
  echo "Harness gate (fast) found problems in the change you just made. Fix them before continuing:" >&2
  echo "$REPORT" >&2
  exit 2
fi
exit 0
