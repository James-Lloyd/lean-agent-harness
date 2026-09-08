#!/usr/bin/env bash
# Do the four PowerShell/cmd.exe destructive patterns reach the denylist, and do the controls stay
# out of it? Takes a hook path so the same cases can be run against the pre-fix and post-fix hooks.
#
# NOTE ON THE FIXTURES: only the PowerShell CMDLET NAMES are assembled from fragments. The cmd.exe
# switch forms below are written out verbatim and DO trip the guard that watches an agent's Bash
# calls — that is unavoidable here, since the whole point is to feed the hook the literal text it
# must deny. Run this script by path; do not paste its cases into a shell command.
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
echo "--- CONCATENATED and CHAINED switches: cmd.exe accepts these; live-fire confirmed ---"
# `rd /s/q <dir>` really deleted a populated tree in cmd.exe on Windows 11. A whitespace-only
# trailing boundary let every one of these through, which was a NET LOSS against the original
# adjacent-only pattern. These six are the regression pins for that.
run "rd /s/q C:\\\\temp\\\\x"      "rd /s/q C:\\\\temp\\\\x"
run "rmdir /s/q C:\\\\temp\\\\x"   "rmdir /s/q C:\\\\temp\\\\x"
run "rd /q/s C:\\\\temp\\\\x"      "rd /q/s C:\\\\temp\\\\x"
run "del /s/q C:\\\\temp\\\\*"     "del /s/q C:\\\\temp\\\\*"
run "cmd /c rd /s/q C:\\\\temp\\\\x" "cmd /c rd /s/q C:\\\\temp\\\\x"
run "rd C:\\\\temp\\\\x /s&&echo done" "rd C:\\\\temp\\\\x /s&&echo done"
echo "--- switch run led by another flag, and no space at all (live-fired: these really delete) ---"
run "del /f/s/q C:\\\\temp\\\\*"   "del /f/s/q C:\\\\temp\\\\*"
run "del /a/s/q C:\\\\temp\\\\*"   "del /a/s/q C:\\\\temp\\\\*"
run "del /f/q C:\\\\temp\\\\f.txt" "del /f/q C:\\\\temp\\\\f.txt"
run "rd/s/q C:\\\\temp\\\\x"       "rd/s/q C:\\\\temp\\\\x"
run "rmdir/s/q C:\\\\temp\\\\x"    "rmdir/s/q C:\\\\temp\\\\x"
echo "--- switch run ended by > ) or , : cmd.exe terminators a space-list boundary misses ---"
# The two most idiomatic batch spellings there are. Both live-fired and DELETED populated trees.
run "rd C:\\\\temp\\\\x /s/q>nul"    "rd C:\\\\temp\\\\x /s/q>nul"
run "rmdir C:\\\\temp\\\\x /s/q>nul" "rmdir C:\\\\temp\\\\x /s/q>nul"
run "(rd C:\\\\temp\\\\x /s/q)"      "(rd C:\\\\temp\\\\x /s/q)"
run "if exist C:\\\\temp\\\\x (rd C:\\\\temp\\\\x /s/q)" "if exist C:\\\\temp\\\\x (rd C:\\\\temp\\\\x /s/q)"
run "rd C:\\\\temp\\\\x /s/q,"       "rd C:\\\\temp\\\\x /s/q,"
run "del C:\\\\temp\\\\*.txt /s/q>nul"   "del C:\\\\temp\\\\*.txt /s/q>nul"
run "del C:\\\\temp\\\\*.txt /f/s/q>nul" "del C:\\\\temp\\\\*.txt /f/s/q>nul"
echo "--- controls (must stay ALLOWED) ---"
# SF1: POSIX absolute paths beginning with the switch letter. rmdir cannot delete a non-empty
# directory on POSIX, and /srv /sys /sbin /snap /share /storage are ordinary roots.
run "rmdir /srv/cache"           "rmdir /srv/cache"
run "rmdir /sys/fs/cgroup/x"     "rmdir /sys/fs/cgroup/x"
run "rd /storage/tmp"            "rd /storage/tmp"
run "git status"                 "git status"
run "npm test"                   "npm test"
run "$RI stale.tmp"              "$RI stale.tmp"
# Two-letter switch tokens: cmd.exe REFUSES these ("Parameter format not correct", live-fired both
# orders, target survived), so not matching them costs no real coverage and avoids over-blocking.
run "rd /sq C:\\\\temp\\\\x"       "rd /sq C:\\\\temp\\\\x"
run "rd /qs C:\\\\temp\\\\x"       "rd /qs C:\\\\temp\\\\x"
echo "--- deliberate shared false positive: DENIED by design, on BOTH twins ---"
run "docs mention del /s only"   "echo the del /s switch is documented"
