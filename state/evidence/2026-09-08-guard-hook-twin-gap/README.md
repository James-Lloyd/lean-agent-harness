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
| 1 | the `.sh` hook at the pre-fix commit `1621ae7` | all eleven destructive cases `rc=0` **ALLOWED** (`results-2026-09-08.txt` lines 2–10 and 12–13) |
| 2 | the `.sh` hook after the fix | all eleven `rc=2` **DENIED** (lines 24–32 and 34–35); the six controls still `rc=0` (lines 37–42) |
| 2b | one new pattern in a 190,920-byte multi-line payload, and again against a copy of the hook with `set -euo pipefail` injected | **DENIED** both ways; the same-size benign control **ALLOWED** (lines 46–48) |
| 3 | the `.ps1` twin, same cases | identical to arm 2, case for case (lines 51–68) |

Arm 1 is pinned to the commit SHA, not to `origin/main`. Defaulting it to a branch would have made
the proof self-falsifying: once this change merges, `origin/main` *is* the fixed hook, arm 1 would
print eleven DENIED lines, and the committed results file would contradict the script that claims to
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

## What the fresh-context review changed

The first version of this change shipped the two cmd.exe patterns as the `.ps1` had always written
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

Both are fixed in the same diff, in both twins, by requiring the switch to be a standalone token:
`[^|]*` before it so flag order does not matter, and a trailing space-or-end boundary so a path
cannot impersonate it. The six controls and the two flag-order cases are now pinned in both suites.

The lesson is now a ratchet in `AGENTS.md`: **probe a new denylist pattern against the real command
vocabulary of the platform it will run on before writing down what it costs.** The original
false-positive list below was assembled from prose examples, and a list built that way will always
undercount.

## One shared false positive, kept deliberately

Prose containing the literal `del /s` — for instance `echo the del /s switch is documented` — is now
denied on the bash side too. It was already denied by the `.ps1` twin (arm 3, last line), so this is
the twins converging, not a new defect. The commit-message scrub covers the common real case
(`git commit -m "… del /s …"` is scrubbed before the patterns run). Narrowing *this* one would mean
refusing to deny a genuine `del /s` typed as the first thing on a line, so it stays. It is the only
one left: the three POSIX-path over-blocks above were real and were fixed, not accepted.

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
| bash `run-tests.sh` | 325 / 0 | **340 / 0** |
| PowerShell 5.1 `run-tests.ps1` | 333 / 0 | **347 / 0** |

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
