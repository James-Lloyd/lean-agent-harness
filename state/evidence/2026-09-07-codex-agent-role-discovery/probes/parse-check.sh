#!/usr/bin/env bash
# `bash -n` over every probe script in this directory. Counting them here rather than in prose
# because round 1 shipped three different counts of these scripts across three surfaces.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
n=0
for f in *.sh; do
  n=$((n+1))
  if bash -n "$f"; then echo "ok   $f"; else echo "FAIL $f"; rc=1; fi
done
echo "checked $n scripts; rc=$rc"
exit "$rc"
