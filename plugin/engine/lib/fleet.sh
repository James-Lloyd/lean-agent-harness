#!/usr/bin/env bash
# fleet.sh (lib) — pure logic for the fleet runner (harness/fleet.sh): which tasks may run in
# parallel (bash mirror of lib/fleet.ps1; needs jq).
#
# The rule: parallel tasks must be FILE-OWNERSHIP-PARTITIONED. A task is fleet-eligible only if it
# declares a non-empty `files` ownership list in state/tasks.json; two tasks whose ownership overlaps
# (same path, or one inside the other) NEVER run in the same batch — overlapping work runs
# sequentially instead. Conflict avoidance beats conflict resolution.

# Normalize an ownership entry: forward slashes, strip a trailing glob (/* or /**) and trailing
# slashes, case-fold (parity with the Windows side).
_fleet_norm() {
  printf '%s' "$1" | tr 'A-Z\\' 'a-z/' | sed -E 's|/\*\*?$||; s|/+$||'
}

# fleet_overlap <list-a> <list-b> — newline-separated ownership lists; exit 0 if they overlap.
# FAIL-CLOSED: an empty/blank entry overlaps everything.
fleet_overlap() {
  local a b na nb
  while IFS= read -r a; do
    na="$(_fleet_norm "$a")"
    [ -z "$na" ] && return 0
    while IFS= read -r b; do
      nb="$(_fleet_norm "$b")"
      [ -z "$nb" ] && return 0
      [ "$na" = "$nb" ] && return 0
      case "$na" in "$nb"/*) return 0;; esac
      case "$nb" in "$na"/*) return 0;; esac
    done <<< "$2"
  done <<< "$1"
  return 1
}

# fleet_select_tasks <tasks.json> <maxWorkers> — echoes the selected task ids, one per line, in
# manifest (= priority) order. Eligible: status todo|planned AND non-empty `files` ownership AND no
# overlap with an already-picked task. Tasks without ownership are silently ineligible — the planner
# declares ownership; the fleet never guesses it.
fleet_select_tasks() {
  local manifest="$1" max="$2" n i status files j overlap
  local picked_ids=() picked_files=()
  n="$(jq -r '.tasks | length' "$manifest")"
  for (( i = 0; i < n; i++ )); do
    [ "${#picked_ids[@]}" -ge "$max" ] && break
    status="$(jq -r ".tasks[$i].status" "$manifest")"
    { [ "$status" = "todo" ] || [ "$status" = "planned" ]; } || continue
    files="$(jq -r ".tasks[$i].files // [] | .[]" "$manifest")"
    [ -n "$files" ] || continue
    overlap=0
    for j in "${picked_files[@]:-}"; do
      [ -z "$j" ] && continue
      if fleet_overlap "$files" "$j"; then overlap=1; break; fi
    done
    [ "$overlap" = "1" ] && continue
    picked_ids+=("$(jq -r ".tasks[$i].id" "$manifest")")
    picked_files+=("$files")
  done
  [ "${#picked_ids[@]}" -gt 0 ] && printf '%s\n' "${picked_ids[@]}"
  return 0
}
