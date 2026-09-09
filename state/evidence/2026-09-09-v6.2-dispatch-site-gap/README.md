# 2026-09-09 — V6.2: a codex route with no dispatch site

**Verdict: GREEN.** The claim `/harness-doctor` check 10(i) now grades, measured rather than asserted:

> `"codex"` is legal syntax on every phase, but `plan`, `explore` and `docs` have **no headless
> dispatch site** — `loop.*` and `fleet.*` resolve no such phase — so a loop run silently ignores the
> value and runs Claude anyway. `docs` has no interactive path either (`/gc` carries no routing
> block), which makes `docs: "codex"` a key nothing anywhere reads.

## The measurement

`probes/dispatch-gap.sh`, arm 1: a real `loop.sh --mode auto` iteration over a config that routes
`plan`, `explore` **and** `docs` to codex, with a `codex` on PATH that records every invocation.

```
models the claude arm was asked for: impl-x judge-x
codex invocations recorded:          0
```

Zero contact with the codex binary — not an exec, not even an availability probe. The implement and
review phases both dispatched, so the run genuinely happened; the three routed phases produced
nothing at all.

## Why arm 2 exists, and what it does NOT say

"codex was never invoked" is equally consistent with a PATH stub the loop could never have reached.
Arm 2 re-runs the same loop with `review` routed to codex — a phase the engine *does* honour — and
the stub records one contact. The contrast is the measurement: **honoured phase → contact with the
codex binary; unhonoured phase → none.**

The stub exits 97 on purpose, so that contact is the engine's availability probe
(`codex login status`) and the phase then falls back to Claude. **Arm 2 does not show a completed
codex exec** and is not evidence about the exec path — V6.1's evidence dir covers that. It is a
reachability control and nothing more.

## What is pinned in the suites

Both twins gained 15 assertions (bash 381 → 396, PS 388 → 403):

- six **positive**: `loop.{sh,ps1}` really do resolve `implement`, `review`, `evaluate`;
- six **negative**: they really do not resolve `plan`, `explore`, `docs`;
- three **doc pins** on the distinctive text of the new doctor table and the routing skill's warning.

The positive six are the negative six's control: they use the identical grep shape, so a typo that
made the negatives vacuous would take the positives red in the same run. (Verified by arithmetic on
the run: +15 assertions, 0 failed.)

If someone later adds a dispatch site for one of those phases, the negative assertion goes red and
the doctor table must be corrected in the same change — which is the point.

## What this does NOT show

- **That routing `plan`/`explore` to codex works interactively.** `commands/work.md` says `/work`
  dispatches them through the codex lib; that path is untested here and is why 10(i) grades those two
  ⚠️ (interactive-only) rather than ❌.
- **Anything about `fleet.*`.** Only `loop.*` was exercised. The suite assertions cover `loop.{sh,ps1}`.
- **Cost or latency.** No paid call was made by either arm; nothing here licenses a figure.
