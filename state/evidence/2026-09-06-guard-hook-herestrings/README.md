# Guard-hook here-string conversion — evidence (2026-09-06)

Task: *"Convert the remaining `printf '%s' "$x" | grep -q` sites in `plugin/hooks/block-destructive.sh`
and `protect-specs.sh` (+ `migrate.sh`, `codex-setup.sh`) to here-strings"* (`state/fix_plan.md`).

## What was converted

| file | sites | `pipefail`? | status before |
|---|---|---|---|
| `plugin/hooks/block-destructive.sh` | 10 | no | latent |
| `plugin/hooks/protect-specs.sh` | 1 | no | latent |
| `plugin/engine/migrate.sh` | 4 | **yes** (line 11) | live, benign inputs |
| `plugin/engine/codex-setup.sh` | 1 | **yes** (line 35) | **live fail-open** |

16 sites. `grep -rn "printf '%s'.*| *grep" plugin/` now returns only the three prose comments that
*describe* the anti-pattern.

## The defect, measured

`pipefail-proof.sh` builds a mutant by reversing the conversion on the one site that matches `rm -rf`,
then runs both hooks against a real payload:

```
  payload / hook                         MUTANT     SHIPPED
  multi-line 195 KB, hook as-is          2          2
  multi-line 195 KB, +pipefail           0          2      <-- the defect
  SINGLE-line 200 KB, +pipefail          2          2
```

`2` = denied, `0` = **allowed**. Row 2: with `set -euo pipefail` added, the pre-conversion hook lets a
real `rm -rf /` through. Row 1 shows why it was latent — the hooks deliberately set no shell options,
so the guard was armed only by that omission, and "harden the hook with `set -euo pipefail`" was a
one-line change that would have disarmed every pattern.

## Two findings the task line did not anticipate

**1. `codex-setup.sh:162` could fail without anyone hardening anything.** It ran
`tr -d '\r' < "$gi" | grep -qx '\.codex/'` inside an `if !` guard, in a file that *does* set
`pipefail`. `grep -qx` exits at the match, `tr` dies of SIGPIPE, the pipeline reports 141, the guard
concludes "`.codex/` absent" — and appends it again, on every run.

The size it takes is **not** the 64 KiB pipe buffer, and the first draft of this document said it was.
With an external producer (`tr`) instead of the `printf` builtin, grep's own read buffer absorbs much
more. Bisected on Git Bash 5.3.9:

| `.gitignore` | `tr \| grep -qx` PIPESTATUS |
|---|---|
| 114 KB | `(0 0)` — no failure |
| 289 KB | `(141 0)` — **fail-open** |

The first regression fixture written here was 114 KB, chosen from the "past 64 KiB" figure carried
over from `money_signal`, and it passed against the broken code. The shipped fixture is 10 000 lines
/ 289 KB, verified to append a duplicate on the mutant and not on the shipped script. Every
producer/consumer pair has its own threshold; it has to be bisected, not inherited.

**2. The regression fixture shipped in PR #16 could not have caught this.** Row 3 above: it was a
single 200 KB line, and it denies on the broken hook too. Reproducing the fail-open needs **two**
conditions, and the recorded rule only had one:

* the match must sort **first**, so grep can exit while printf is still writing — this was known; and
* the bulk must follow a **newline**, because grep cannot match until it has read a complete line. On
  one long line grep must consume all 200 KB before it can match, printf finishes writing, and no
  SIGPIPE ever occurs.

The `money_signal` fixture satisfies both by accident of shape (`const p = price * 2\n` then filler),
which is why *that* proof is sound. The hook fixture satisfied only the first. It read like a
regression test and pinned only the happy path — worse than no fixture, because it retires the
question. Corrected in `plugin/engine/AGENTS.md` and in design-doc 001, which stated the one-condition
version.

## Tests

`harness/tests/run-tests.sh` gains two assertions. Only the second discriminates, and the suite says
so in a comment so nobody mistakes the pair for two proofs:

* *blocks a destructive command in a MULTI-LINE oversized payload* — 2 on both mutant and shipped;
  coverage of the input shape, not proof.
* *…and still blocks it with `set -euo pipefail` injected into the hook* — **0 on the mutant, 2 on the
  shipped hook**. This is the regression proof.

The pipefail copy is built with `head`/`tail`, not `sed '2i …'`: the bare `i` form is a GNU extension
and this suite has to run under BSD/macOS sed (engine `AGENTS.md`).

`harness/tests/run-tests.ps1` gains the multi-line shape for symmetry. The `.ps1` hook matches
in-process with `-match` over the whole string, so it was never exposed; the assertion exists so a
future rewrite of either twin cannot quietly lose the case.

## Behavioural equivalence of the swap

`<<<` appends a trailing newline where `printf '%s'` did not. For every pattern at these 16 sites
that changes no match: grep is line-oriented and treats end-of-input as end-of-line either way, so the
`$`-anchored alternations (`(\||;|&|$)`) behave identically.

**The swap is not equivalent in general, though**, and the first draft of this document claimed it was.
The forms differ on empty input, because `<<<` supplies one empty *line* where `printf '%s' ""`
supplies no input at all:

```
printf '' | grep -Eq 'a*'   -> 1   (no line to match)
grep -Eq 'a*' <<< ""        -> 0   (one empty line, and 'a*' matches it)
```

So any pattern that can match the empty string flips from "no match" to "match". None of the 16
converted sites uses such a pattern — every one requires literal text — and in `block-destructive.sh`
lines 19 and 34 guarantee `$scan` is non-empty regardless. The conversion is safe here; the general
claim is not, and a future site with a `*`-quantified pattern must not lean on this section.

## Gate

| suite | result |
|---|---|
| `harness/tests/run-tests.sh` | **325 / 0** (321 at the tick, +4 from the review fixes) |
| `harness/tests/run-tests.ps1` | **333 / 0** (unchanged — the review fixes were sh-side and docs) |
| `bash -n` over all 26 shell scripts | clean |

The four added by the fresh-context review are the ones that make the other two converted files
load-bearing rather than merely changed:

* `protect-specs degraded (no jq) blocks specs/ in a MULTI-LINE oversized payload` — and the same
  with `pipefail` injected. Pre-fix that second one exits **0**, admitting a write to `specs/`.

  Forcing that branch took two attempts, and the first was the same defect one level up. `env -i
  PATH=/usr/bin:/bin` looks like it strips jq, but on Linux **jq lives in `/usr/bin`** — so the proof
  silently skipped on the Linux CI job and ran only on Windows. Caught by reading the CI log rather
  than the exit status: `(skipping the degraded protect-specs proof — jq is reachable from a bare
  PATH)`. It now builds a temp dir holding exec wrappers for only the commands the degraded branch
  uses (`cat`, `grep` — everything else it touches is a bash builtin) and points `PATH` at that,
  invoking bash by absolute path since `PATH` no longer resolves it. That is jq-free on any host.

  It also carries a **positive control** — the same forced environment on a non-spec path must exit
  `0`. Without one, a hook that died early for an unrelated reason (a command missing from the
  stripped `PATH`) would look like a pass, because "denied" and "crashed" are both non-zero.
* `an OVERSIZED .gitignore already containing .codex/ is left alone` — 289 KB, verified to append a
  duplicate on the mutant and not on the shipped script, with a positive control confirming the step
  actually runs (`codex-setup.sh` resolves `PLUGIN_ROOT` from its own directory, so a mutant copied
  to `/tmp` silently exits before ever reaching the check).

`plugin/.claude-plugin/plugin.json` 0.3.8 → **0.3.9** — shipped hook behaviour changed, so the version
moves in the same diff (2026-08-12 ratchet).

## Reproduce

```
bash state/evidence/2026-09-06-guard-hook-herestrings/pipefail-proof.sh .
```

Recorded output: `pipefail-proof.txt`. The script rebuilds the mutant from the shipped hook on each
run and aborts if the expected here-string site is gone, so it cannot rot into a no-op.
