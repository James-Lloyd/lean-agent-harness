# Guard-hook twin gap closed — the four PowerShell-form patterns are now in `block-destructive.sh`

**Task:** `state/fix_plan.md` — *"Close the guard-hook twin gap: `block-destructive.sh` lacks four
PowerShell-form patterns that `block-destructive.ps1` has."*
**Date:** 2026-09-08 · **Branch:** `worktree-guard-hook-twin-gap` · **Plugin:** 0.3.9 → 0.4.0

## What was wrong

`run.mjs` dispatches `block-destructive.ps1` on win32 and `block-destructive.sh` everywhere else. The
`.ps1` body has carried four destructive forms since it shipped; the `.sh` body had none of them:

```
Remove-Item … -(Recurse|Force)      (rd|rmdir) /s      del /[sq]      Format-Volume|Clear-Disk|Clear-Content
```

That is not a Windows-only concern. The PowerShell tool runs on POSIX via `pwsh` — the `.sh` file's
own spec-lock block already says so and already matches `Remove-Item` there — and the `.sh` hook is
also the one Codex loads under its shell-tool matcher. So on POSIX an agent driving `pwsh` could
issue a recursive delete and match nothing in the always-on denylist.

Found during the Codex 0.153.4 re-verification and filed rather than fixed there, because that branch
was a verification pass: `state/evidence/2026-09-06-codex-0153-reverify/README.md`, section *"A twin
gap this turned up"* (now carrying a forward pointer here).

## The measurement

One re-runnable script carries every arm, calls no model, and costs nothing:

```
bash state/evidence/2026-09-08-guard-hook-twin-gap/probes/run-both-arms.sh
```

Full captured output, unfiltered: **`results-2026-09-08.txt`**. Per arm:

| Arm | What it runs | Result |
|-----|--------------|--------|
| 1 | the `.sh` hook at the pre-fix commit `1621ae7` | all twenty-nine destructive cases `rc=0` **ALLOWED** (`results-2026-09-08.txt` lines 2–10, 12–13, 15–20, 22–26, 28–34) |
| 2 | the `.sh` hook after the fix | all twenty-nine `rc=2` **DENIED** (lines 48–56, 58–59, 61–66, 68–72, 74–80); the eight controls still `rc=0` (lines 82–89) |
| 2b | one new pattern in a 190,920-byte multi-line payload, and again against a copy of the hook with `set -euo pipefail` injected | **DENIED** both ways; the same-size benign control **ALLOWED** (lines 94–96) |
| 3 | the `.ps1` twin, same cases | identical to arm 2, case for case (lines 99–136) |
| 4 | **the differential** — all five pattern generations extracted from the git blobs and evaluated over a 1,342-form corpus | 462 forms **gained**, 128 lost, every loss carrying a recorded live-fire verdict (lines 139–150) |

**Arm 4 is the one this task earned the hard way.** Three of the four pattern generations shipped a
regression, and each regressing round is one that had not computed the set "denied by a predecessor,
allowed by this one". So the differential is now an *arm* rather than a discipline: it extracts each
generation's regexes straight from the git blobs (never transcribed — a transcription slip would make
the differential agree with itself), evaluates them all over a generated corpus, and fails on any
loss that is not on a list of adjudicated ones. The adjudicated list can only be extended by a
live-fire verdict: a form cmd.exe *refuses* is not lost coverage, and a benign command an earlier
generation over-blocked is a deliberate removal. Everything else is a blocker.

It also carries a positive control on its own filter, because "no unadjudicated losses" reassures
only if the filter can still report one — an over-broad adjudication pattern would silently swallow a
real regression, which is precisely the failure this arm exists to catch. The six round-4 regressions
are checked against the filter every run and must survive it.

Arm 1 is pinned to the commit SHA, not to `origin/main`. Defaulting it to a branch would have made
the proof self-falsifying: once this change merges, `origin/main` *is* the fixed hook, arm 1 would
print twenty-nine DENIED lines, and the committed results file would contradict the script that claims to
produce it.

**Arm 1 is the one that matters.** Against the pre-fix hook these commands return a wrong *value* — a
real recursive delete is admitted — rather than throwing. That is what makes the new suite assertions
a regression proof and not a test of the regex syntax (`AGENTS.md`, 2026-09-06: *"a mutation check
must make the pre-fix code return a WRONG ANSWER, not throw"*).

**Arm 2b exists because a guardrail predicate is not verified until it has run over a real input at
real size** (`AGENTS.md`, 2026-09-06). The four new patterns go through the same
`grep -iEq <<< "$scan"` loop as the rest, so they inherit the here-string form that replaced the
SIGPIPE-prone `printf | grep`. That is a reason to expect them to hold, not evidence that they do. The
fixture puts its bulk *after* a newline, because grep cannot exit early until it has read a whole
line, and only an early exit can make the writer die of SIGPIPE. The benign control at the same size
is what stops "DENIED" from merely proving that something in a 190 KB payload trips the guard.

## What the fresh-context reviews changed — four rounds, and three of the four fixes were wrong

**Round 1.** The first version shipped the two cmd.exe patterns as the `.ps1` had always written
them, matching the switch *adjacent* to the command. A fresh-context review measured that shape
against real POSIX command vocabulary and found it wrong in both directions at once:

* **Over-blocking.** `rmdir /srv/cache`, `rmdir /sys/fs/cgroup/x` and `rd /storage/tmp` were all
  denied, because an absolute path whose first segment starts with the switch letter looks like the
  switch. `/srv`, `/sys`, `/sbin`, `/snap`, `/share` and `/storage` are ordinary roots, `rmdir` on
  POSIX cannot even delete a non-empty directory, and the `.sh` hook is precisely the one that runs
  on POSIX. That is a harmless command denied on the platform the file serves.
* **Under-blocking.** `rmdir /q /s build` and `del /f /s *.log` were *allowed* by both twins. Both
  are real recursive deletes; an adjacent-only match simply misses them when the flags are ordered
  the other way.

**Round 2, and this is the part worth reading.** The obvious repair for the over-block — require a
*space-or-end* boundary after the switch, so a path cannot impersonate it — shipped a real **bypass**,
and a second fresh-context review caught it by differentially diffing the new pattern against the one
it replaced. cmd.exe accepts **concatenated** switches, so the character after the switch is `/`, not
whitespace. Every one of these was denied by the crude original and *allowed* by the careful
replacement:

```
rd /s/q <dir>        rmdir /s/q <dir>      rd /q/s <dir>
del /s/q <dir>\*     cmd /c rd /s/q <dir>  rd <dir> /s&&echo done
```

These are not theoretical. Live-fired in real cmd.exe on Windows 11, `rd /s/q <dir>` deleted a
populated three-level tree and `del /s/q <dir>\*` deleted files at two depths, both exit 0. And
`cmd /c rd /s/q <dir>` is the exact phrasing an agent uses from the Bash tool on Windows. A branch
whose entire purpose was to *close* a guard gap was one review away from shipping a **net loss of
coverage** on the most safety-critical file in the repo.

Round 2's answer was to make the boundary a character *class* — `([[:space:];&"/]|$)` — plus `[qs/]*`
on the `rd` arm. That is the third wrong answer, and a third review live-fired past it as well.

**Round 3, and the reason this section exists.** The character class is a strict improvement over
round 2 and loses nothing, which the third review confirmed mechanically over a 12,960-form corpus.
But it is still reasoning about *where the switch usually sits*, and two more real destructive forms
walk past it — both pre-existing, missed by every generation including the long-shipped `.ps1`:

```
del /f/s/q <dir>\*    a switch run led by another flag; the canonical Windows build-script idiom
rd/s/q <dir>          no space at all between the command word and the switch
```

Both live-fired: the first deleted files at two depths, the second removed a populated tree. And the
`/` in the boundary class had meanwhile created a *new* false-positive family — any text carrying the
word `del` next to a path segment ending in `s` or `q`, so `node del.js --out /logs/` and
`git log -- del /docs/` were denied.

The answer was to stop describing *where the switch sits* and describe cmd.exe's switch **grammar**:
a switch is a run of one-letter `/x` segments, it may sit anywhere in the command, and the separating
space is optional. That part was right and still stands. The run-*end* was still written as a list of
terminators, `([[:space:];&"]|$)`, and that was the fourth wrong answer.

**Round 4.** A fourth review built a 1,992-form corpus, evaluated all four generations' regexes
straight from the git blobs, and computed the one set that matters: denied by a predecessor, allowed
by the new pattern. It was not empty. A terminator list is always short by something, and cmd.exe
also ends a switch run at `>`, `)` and `,`:

```
rd <dir> /s/q>nul                       rmdir <dir> /s/q>nul       rd <dir> /s/q,
if exist <dir> (rd <dir> /s/q)          (rd <dir> /s/q)            del <dir>\*.txt /s/q>nul
```

Every one live-fired and deleted its target, and the first two spellings are about as idiomatic as
batch gets. Round 3 had caught them *by accident* — its boundary class contained `/`, so it matched
at the inner separator of a multi-segment run and never cared what followed. Removing `/` on
grammatical grounds removed the accident with it.

So the boundary is now written as **"not a continuation"** rather than as a list of terminators:

```
\b(rd|rmdir)\b([^|]*[[:space:]])?(/[a-z])*/s(/[a-z])*([^a-zA-Z/]|$)
\bdel\b([^|]*[[:space:]])?(/[a-z])*/[sq](/[a-z])*([^a-zA-Z/]|$)
```

A one-letter segment must simply not be followed by another **letter** (that would make it a
multi-letter token cmd.exe refuses) or by `/` (already consumed by the segment run). Nothing else
needs enumerating, which is the point: there was no list left to be short by.

The negatives were live-fired too, which is what licenses the narrowness: `rd /sq`, `rd /qs` and
`rd /s/build` are all **refused by cmd.exe itself** — *"Parameter format not correct"*, *"Invalid
switch"*, target survived in every case — so matching them would buy no coverage and cost
over-blocking. Twenty-nine destructive forms now deny on both twins; eight controls pass.

Four ratchets in `AGENTS.md` came out of this, and they get progressively more expensive. Probe a
new denylist pattern against the platform's real command vocabulary before writing down what it
costs. **A fix for an over-block is itself a loosening, so it gets differentially diffed against its
predecessor over every form the old pattern caught** — a pattern that is merely *better reasoned* is
not therefore safer. **And write the rule against the foreign shell's GRAMMAR**: enumerate the token
forms its parser accepts and live-fire each, positives and negatives, so boundary characters and flag
order fall out as consequences instead of being guessed at. Three attempts were spent guessing.

## One shared false positive, kept deliberately

Prose containing the literal `del /s` — for instance `echo the del /s switch is documented` — is now
denied on the bash side too. It was already denied by the `.ps1` twin (arm 3, last line), so this is
the twins converging, not a new defect. The commit-message scrub covers the common real case
(`git commit -m "… del /s …"` is scrubbed before the patterns run). Narrowing *this* one would mean
refusing to deny a genuine `del /s` typed as the first thing on a line, so it stays.

It is the only one left, and unlike the earlier claim to that effect this one is measured rather than
recalled: the three POSIX-path over-blocks were fixed, and so was the `del`-beside-a-path family that
round 2's boundary class introduced. Both are pinned as negative controls in both suites, which is
what stops the accounting drifting again the next time the pattern moves.

It bit immediately and is worth knowing about: the first attempt to write *this change's own commit
message* was denied, because the message quotes the pattern it adds. The workaround is the one
already in `AGENT_NOTES.md` for the other denylist literals — write the message to a scratch file and
`git commit -F <file>`, so the text never appears in the shell command the hook scans.

## Two twin divergences that remain, both measured, neither exploitable

Recorded so the next reviewer does not have to rediscover them. Both were found by differential
probing of the two hooks on identical payloads.

* **Exotic Unicode separators.** `rmdir<NBSP>/s build` and the em-space variant are denied by the
  `.sh` hook and allowed by the `.ps1` one: GNU grep's `[[:space:]]` accepts them in a UTF-8 locale,
  while PowerShell 5.1's `[Console]::In.ReadToEnd()` mis-decodes the bytes so the word boundary is
  lost. Neither character is a real cmd.exe argument separator, so nothing executable slips through
  the permissive side.
* **Newlines inside a command.** `Remove-Item build\n-Recurse -Force` is allowed by `.sh` and denied
  by `.ps1`, because `[^|]*` spans newlines under .NET while grep is line-based. This is inherited,
  not introduced — five pre-existing patterns (`rm`, `find`, `dd`, `git clean`, the exfil rule)
  behave identically — and the permissive side is not valid PowerShell anyway.

## Gate

| Suite | Before | After |
|-------|--------|-------|
| bash `run-tests.sh` | 325 / 0 | **362 / 0** |
| PowerShell 5.1 `run-tests.ps1` | 333 / 0 | **369 / 0** |

Fifteen new assertions on the bash side, fourteen on the PowerShell side: nine denials, two
flag-order denials, and four negative controls (a bare `Remove-Item` with no destructive flag, plus
the three POSIX paths that must not be mistaken for switches) per twin. Only `Remove-Item` was pinned
on the PowerShell side before, so three of its four patterns had been shipping unasserted — the twin
whose *behaviour* was right had the weaker tests, which is how the over-block survived there for
months without anyone noticing.

## Why the plugin version moved

`plugin/.claude-plugin/plugin.json` 0.3.9 → 0.4.0. A shipped hook's *behaviour* changed, and
consumers get that hook from the plugin cache; an unbumped version leaves `/plugin update` serving a
mixed build (`AGENTS.md`, 2026-08-12).
