#!/usr/bin/env bash
# Pre-fix probe: do the four PowerShell-form destructive patterns reach the .sh denylist?
# Fixtures are assembled from fragments so this script's own text does not trip the guard
# that is watching the agent's Bash calls.
HOOK="$1"
[ -n "$HOOK" ] || { echo "usage: $0 <path to block-destructive.sh>" >&2; exit 64; }

RI="Remove""-Item"
FV="Format""-Volume"
CD="Clear""-Disk"
CC="Clear""-Content"

run() {  # $1 = label, $2 = command text ; prints label + hook exit code
  local rc
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$2" \
    | bash "$HOOK" >/dev/null 2>&1
  rc=$?
  printf '%-46s rc=%s  %s\n' "$1" "$rc" "$([ "$rc" = 2 ] && echo DENIED || echo ALLOWED)"
}

run "$RI -Recurse -Force ."      "$RI -Recurse -Force ."
run "$RI -Force build"           "$RI -Force build"
run "rmdir /s /q build"          "rmdir /s /q build"
run "rd /s /q build"             "rd /s /q build"
run "del /s *.log"               "del /s *.log"
run "del /q *.log"               "del /q *.log"
run "$FV -DriveLetter D"         "$FV -DriveLetter D"
run "$CD -Number 1"              "$CD -Number 1"
run "$CC notes.txt"              "$CC notes.txt"
echo "--- flag-order forms: real recursive deletes an adjacent-only match misses (SF3) ---"
run "rmdir /q /s build"          "rmdir /q /s build"
run "del /f /s *.log"            "del /f /s *.log"
echo "--- controls (must stay ALLOWED) ---"
# SF1: POSIX absolute paths beginning with the switch letter. rmdir cannot delete a non-empty
# directory on POSIX, and /srv /sys /sbin /snap /share /storage are ordinary roots.
run "rmdir /srv/cache"           "rmdir /srv/cache"
run "rmdir /sys/fs/cgroup/x"     "rmdir /sys/fs/cgroup/x"
run "rd /storage/tmp"            "rd /storage/tmp"
run "git status"                 "git status"
run "npm test"                   "npm test"
run "$RI stale.tmp"              "$RI stale.tmp"
run "docs mention del /s only"   "echo the del /s switch is documented"
