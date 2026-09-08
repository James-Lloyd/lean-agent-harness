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
| 1 | the `.sh` hook at `origin/main`, i.e. pre-fix | all nine destructive cases `rc=0` **ALLOWED** (`results-2026-09-08.txt` lines 2–10) |
| 2 | the `.sh` hook after the fix | all nine `rc=2` **DENIED** (lines 18–26) |
| 2b | one new pattern in a 190,890-byte multi-line payload, and again against a copy of the hook with `set -euo pipefail` injected | **DENIED** both ways; the same-size benign control **ALLOWED** (lines 34–36) |
| 3 | the `.ps1` twin, same cases | identical to arm 2, case for case (lines 39–51) |

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

## One shared false positive, kept deliberately

Prose containing the literal `del /s` — for instance `echo the del /s switch is documented` — is now
denied on the bash side too. It was already denied by the `.ps1` twin (arm 3, last line), so this is
the twins converging, not a new defect. The commit-message scrub covers the common real case
(`git commit -m "… del /s …"` is scrubbed before the patterns run). Narrowing the pattern would have
meant diverging from the shipped `.ps1` behaviour inside the most safety-critical file in the repo,
which is a separate decision from closing the gap. Left as-is and recorded here.

## Gate

| Suite | Before | After |
|-------|--------|-------|
| bash `run-tests.sh` | 325 / 0 | **335 / 0** |
| PowerShell 5.1 `run-tests.ps1` | 333 / 0 | **342 / 0** |

Ten new assertions on the bash side (nine denials plus a negative control that a bare `Remove-Item`
with no destructive flag still passes), nine on the PowerShell side — only `Remove-Item` was pinned
there before, so three of its four patterns had been shipping unasserted.

## Why the plugin version moved

`plugin/.claude-plugin/plugin.json` 0.3.9 → 0.4.0. A shipped hook's *behaviour* changed, and
consumers get that hook from the plugin cache; an unbumped version leaves `/plugin update` serving a
mixed build (`AGENTS.md`, 2026-08-12).
