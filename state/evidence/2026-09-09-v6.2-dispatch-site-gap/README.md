# 2026-09-09 — V6.2: a codex route with no dispatch site

**Verdict: GREEN.** The claim `/harness-doctor` check 10(i) now grades, measured rather than asserted:

> `"codex"` is legal syntax on every phase, but `plan`, `explore` and `docs` have **no headless
> dispatch site** — `loop.*` and `fleet.*` resolve no such phase — so a loop run silently ignores the
> value and runs Claude anyway. `explore` and `docs` have no interactive path either, which makes
> `explore: "codex"` and `docs: "codex"` keys nothing anywhere reads.

**Corrected after fresh-context review.** This dir's first version graded `explore` as
"interactive-only", on the strength of `commands/work.md` naming `explorer`→`explore` in its
phase-mapping list. That list is bookkeeping, not a dispatch site: no `/work` step dispatches an
explore phase, and `work.md`'s own rule is "No subagent ever wraps codex", so exploration is always an
Agent-tool spawn landing on the frontmatter Claude model. `explore` belongs in the same tier as
`docs`. The measurement below never changed — arm 1 always showed zero contact for all three phases;
only the interpretation of *why* was wrong, which is why the re-derivation rule in 10(i) now keys on
dispatch rather than on a mapping list.

**One nuance the ❌ must not overstate:** only the phase's `model` is dead. `engine/codex-setup.*`
resolves `phase_codex_model`/`phase_codex_effort` for every mapped agent phase, ungated by that
phase's route, to write `.codex/agents/<name>.toml` — so a `codex{}` block on `explore`/`docs` IS read
whenever the Codex surfaces are generated.

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
(`codex login status`) and the phase then falls back to its Claude arm — which in arm 2's config also
fails, and the run ends "review invocation failed (claude) — failing closed" (`arm-2-loop.out`). That
is expected and irrelevant to what the arm is for. **Arm 2 does not show a completed codex exec, or a
completed run at all** — it is not evidence about the exec path (V6.1's evidence dir covers that). It
is a reachability control and nothing more.

## What is pinned in the suites

Both twins gained 31 assertions (bash 381 → 412, PS 388 → 419; measured in `gate.txt` beside this
file):

- six **positive**: `loop.{sh,ps1}` really do resolve `implement`, `review`, `evaluate`;
- six **negative**: they really do not resolve `plan`, `explore`, `docs`;
- twelve covering `fleet.{sh,ps1}` the same way (it resolves `implement` only) — added after review,
  because 10(i)'s headless column names `fleet.*` and nothing was pinning it;
- seven **doc pins** on the distinctive text of the doctor table, its re-derivation rule, its
  `codex-setup` carve-out, and the routing skill's tiers.

The doc pins are deliberately **ASCII-only**: PS 5.1's `Get-Content -Raw` decodes these UTF-8 files as
ANSI, so a pin containing the table's `✗` glyph mojibakes and can never match. Measured — it went red
on the PS twin while the bash twin's byte-identical `grep -F` passed.

The positive six are the negative six's control: they use the identical grep shape, so a typo that
made the negatives vacuous would take the positives red in the same run. (Verified by arithmetic on
the run: +15 assertions, 0 failed.)

If someone later adds a dispatch site for one of those phases, the negative assertion goes red and
the doctor table must be corrected in the same change — which is the point.

## What this does NOT show

- **That routing `plan` to codex works interactively.** `/work`'s PLAN step says it routes the planner
  per the routing table in workspace-write mode; that path is untested here, and is why 10(i) grades
  `plan` ⚠️ (interactive-only) rather than ❌.
- **Anything about `fleet.*` at runtime.** Only `loop.*` was exercised by the probe. `fleet.{sh,ps1}`
  are covered by suite assertions (added after review) but were never run here.
- **Cost or latency.** No paid call was made by either arm; nothing here licenses a figure.
