#!/usr/bin/env bash
# ARM 4 — THE DIFFERENTIAL, shipped as an artifact rather than performed once and described.
#
# AGENTS.md 2026-09-08 clause (f): a denylist pattern change is not reviewable until the diff ships
# the machine-checked set "denied by a PREDECESSOR, allowed by THIS one". Four rounds of this task
# ran, three shipped a regression, and each regressing round is one that had not computed this set.
# Round 2 lost the concatenated forms; round 4 lost the `>`/`)`/`,` terminators. Both were found by a
# reviewer doing by hand what this script now does by default.
#
# It extracts each generation's two cmd.exe regexes straight from the git blobs — never transcribed,
# because a transcription error would make the differential agree with itself — and evaluates all of
# them over a generated corpus. Costs nothing, calls no model.
#
#   bash state/evidence/2026-09-08-guard-hook-twin-gap/probes/differential.sh
#
# Exit 0 = no coverage lost against any predecessor. Exit 1 = a form some predecessor denied is now
# allowed; each one is printed, and each needs a live-fire verdict (a form cmd.exe REFUSES is not
# lost coverage, a form that deletes is a blocker).
set -u
repo="$(git rev-parse --show-toplevel)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The predecessor generations, oldest first. G0 is the long-shipped .ps1 from before this task.
# The CURRENT generation is read from the WORKING TREE, not from a commit: the point is to diff the
# change you are about to make, and reading HEAD would silently compare the last commit with itself.
PREV="1621ae7:ps1 59f23d6:sh f17e051:sh 7a021be:sh"

extract() {  # $1 = rev or WORKTREE, $2 = sh|ps1 -> the two cmd.exe regexes, one per line
  local rev="$1" kind="$2" f
  if [ "$kind" = ps1 ]; then f=plugin/hooks/block-destructive.ps1; else f=plugin/hooks/block-destructive.sh; fi
  # Anchor on the WHY strings, which have been stable across every generation, then peel the pattern
  # out of whichever syntax that generation used. Anchoring on the pattern itself would beg the
  # question — the pattern is the thing that changes.
  { if [ "$rev" = WORKTREE ]; then cat "$repo/$f"; else git -C "$repo" show "$rev:$f" 2>/dev/null; fi; } |
    grep -F -e 'recursive rmdir (/s)' -e 'recursive/quiet del' |
    if [ "$kind" = ps1 ]; then
      sed -E "s/^[^']*'//; s/'.*$//"                 # @{ rx = '<PATTERN>'; why = '...' },
    else
      sed -E "s/^[[:space:]]*'//; s/@@.*$//"         # '<PATTERN>@@<why>'
    fi |
    sed -E 's/\\s/[[:space:]]/g'                     # .NET \s -> POSIX, one engine for every gen
}

# Corpus: the shapes a real cmd.exe user or agent writes. Deliberately includes forms cmd.exe
# REFUSES — those must show up as "lost" and then be dismissed by live-fire, not silently omitted.
{
  for cmdw in rd rmdir del; do
    for run in "/s" "/q" "/s /q" "/q /s" "/s/q" "/q/s" "/f/s/q" "/a/s/q" "/f/q" "/sq" "/qs" "/s/q/f"; do
      for sep in " " ""; do
        for trail in "" " x" ">nul" ")" "," ";echo done" "&&echo done" '"' " >out.txt"; do
          printf '%s%s%s%s\n' "$cmdw" "$sep" "$run" "$trail"
          printf '%s C:\\temp\\x %s%s\n' "$cmdw" "$run" "$trail"
          printf 'cmd /c %s %s%s\n' "$cmdw" "$run" "$trail"
          printf 'if exist C:\\temp\\x (%s C:\\temp\\x %s)\n' "$cmdw" "$run"
        done
      done
    done
  done
  # Benign controls — must be allowed by the CURRENT generation; listed so a widening shows up here.
  printf '%s\n' 'rmdir /srv/cache' 'rmdir /sys/fs/cgroup/x' 'rd /storage/tmp' 'del /sbin/foo' \
                'node del.js --out /logs/' 'git log --oneline -- del /docs/' 'rmdir /s/build' \
                'echo del and see /tools/x' 'git status' 'npm test'
} | sort -u > "$tmp/corpus.txt"
echo "corpus: $(wc -l < "$tmp/corpus.txt") unique forms"

i=0
for g in $PREV "WORKTREE:sh"; do
  rev="${g%%:*}"; kind="${g##*:}"
  extract "$rev" "$kind" > "$tmp/rx.$i"
  n=$(wc -l < "$tmp/rx.$i")
  if [ "$n" -ne 2 ]; then
    echo "FAIL: expected 2 regexes from $rev ($kind), extracted $n — the extractor no longer matches"
    echo "      the file's shape, and a differential that silently reads zero patterns proves nothing."
    exit 2
  fi
  : > "$tmp/deny.$i"
  while IFS= read -r rx; do grep -iE "$rx" "$tmp/corpus.txt" >> "$tmp/deny.$i" 2>/dev/null; done < "$tmp/rx.$i"
  sort -u -o "$tmp/deny.$i" "$tmp/deny.$i"
  echo "  gen $i ($rev, $kind): denies $(wc -l < "$tmp/deny.$i")"
  i=$((i+1))
done

cur=$((i-1))
sort -u "$tmp"/deny.[0-$((cur-1))] > "$tmp/prev-union.txt" 2>/dev/null || sort -u "$tmp/deny.0" > "$tmp/prev-union.txt"
comm -23 "$tmp/prev-union.txt" "$tmp/deny.$cur" > "$tmp/lost.txt"
comm -13 "$tmp/prev-union.txt" "$tmp/deny.$cur" > "$tmp/gained.txt"

echo
echo "GAINED (denied now, allowed by every predecessor): $(wc -l < "$tmp/gained.txt")"
echo "LOST   (denied by some predecessor, allowed now):  $(wc -l < "$tmp/lost.txt")"

# ADJUDICATED LOSSES. Every entry here was dismissed by a LIVE-FIRE verdict in real cmd.exe, not by
# reading the regex. Anything that does not match one of these is a NEW loss and fails the arm — the
# whole value of this script is that it can only be quieted by a recorded measurement.
#
#  (a) two-letter switch TOKENS. cmd.exe refuses them: "Parameter format not correct - \"sq\"",
#      both orders, both commands, target survived. Refused by the parser is not lost coverage.
#  (b) deliberate FALSE-POSITIVE REMOVALS. These are benign commands earlier generations denied:
#      POSIX roots whose first segment starts with the switch letter, and the `del`-beside-a-path
#      family that the round-3 boundary class introduced. Losing them is the point.
#      `rmdir /s/build` belongs here too — cmd.exe answers "Invalid switch - \"build\"".
adjudicated='(/sq|/qs)([^a-z]|$)|/srv/|/sys/|/storage/|/sbin/|/logs/|/docs/|/tools/|/s/build'
grep -vE "$adjudicated" "$tmp/lost.txt" > "$tmp/unadjudicated.txt"

# POSITIVE CONTROL for the filter itself. "No unadjudicated losses" is only reassuring if the filter
# is capable of reporting one, and an over-broad `adjudicated` pattern would silently swallow a real
# regression — the failure mode this whole arm exists to prevent. These six forms are the round-4
# regression, live-fired and confirmed to delete; every one MUST survive the filter.
ctl_fail=0
while IFS= read -r ctl; do
  if ! printf '%s\n' "$ctl" | grep -qvE "$adjudicated"; then
    echo "CONTROL FAILED: the adjudicated filter swallows a known real regression: $ctl"
    ctl_fail=1
  fi
done <<'CONTROLS'
rd C:\temp\x /s/q>nul
rmdir C:\temp\x /s/q>nul
(rd C:\temp\x /s/q)
if exist C:\temp\x (rd C:\temp\x /s/q)
rd C:\temp\x /s/q,
del C:\temp\x /f/s/q>nul
CONTROLS
if [ "$ctl_fail" -ne 0 ]; then
  echo "The filter cannot distinguish a real loss from an adjudicated one — fix it before trusting a PASS."
  exit 2
fi

if [ -s "$tmp/unadjudicated.txt" ]; then
  echo
  echo "FAIL — losses with no recorded live-fire verdict:"
  echo "a form cmd.exe REFUSES is not lost coverage; a form that DELETES is a blocker."
  sed 's/^/  /' "$tmp/unadjudicated.txt"
  exit 1
fi
echo "       of which adjudicated by live-fire (refused by cmd.exe, or a deliberate FP removal): all"
echo
echo "PASS: every loss against a predecessor has a recorded live-fire verdict."
