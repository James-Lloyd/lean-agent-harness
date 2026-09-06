# Strict promotion flags — evidence (2026-09-06)

Task: *"(low, pre-existing) Make `Get-PromotionDecision`'s four boolean params strict, matching the sh
twin"* (`state/fix_plan.md`).

## The task's premise was wrong, and the real defect is a different one

The entry — and the two fresh-context reviews it came from (2026-09-05 nit 2, 2026-09-06 nit 8) — said:

> PowerShell coerces ANY non-empty string to `$true`, so a scripted caller passing `"0"`/`"false"`
> would reach AUTO where bash goes HUMAN.

That is what a `[bool]` **assignment** does (`[bool]$x = '0'` is `$true`). It is not what **parameter
binding** does. Probed on a real host (`mutation-proof.ps1`, Windows PowerShell 5.1.26100.9168):

| `-ReviewerConfigured` | pre-fix `[bool]` param | shipped (untyped + `Test-RiskStrictTrue`) | sh twin |
|---|---|---|---|
| `$true`  (bool)   | AUTO          | AUTO  | `1` → AUTO |
| `$false` (bool)   | HUMAN         | HUMAN | `0` → HUMAN |
| `0` (int)         | HUMAN         | HUMAN | HUMAN |
| **`1` (int)**     | **AUTO**      | HUMAN | `"1"` → AUTO |
| **`2` (int)**     | **AUTO**      | HUMAN | **HUMAN** |
| **`-1` (int)**    | **AUTO**      | HUMAN | **HUMAN** |
| **`0.5` (double)**| **AUTO**      | HUMAN | **HUMAN** |
| `"0"` (string)    | *binding error* | HUMAN | HUMAN |
| `"1"` (string)    | *binding error* | HUMAN | AUTO |
| `$null`           | *binding error* | HUMAN | HUMAN |
| `@{}` (hashtable) | *binding error* | HUMAN | HUMAN |

So:

* **Strings never reached AUTO.** They raised `ParameterBindingArgumentTransformationException` — the
  binder refuses them outright. Loud, and fail-closed by accident.
* **The actual fail-open is numeric.** `[bool]` parameters *do* accept numbers, and coerce every
  nonzero one to `$true`. `2`, `-1` and `0.5` each returned **AUTO** on the last gate before
  auto-merge, where the sh twin returns HUMAN. That is a genuine twin divergence in the fail-open
  direction, and it is what this change closes.

The same held for the three precondition flags (`GateGreen`, `ReviewShip`, `E2EEvidence`), which are
pinned separately in both suites.

## Why this mattered for the tests, not just the comment

The first draft of the regression assertions passed **strings** (`'0'`, `'false'`, …), written
straight from the stated premise. Against the pre-fix code those raise an exception — so the suite
would have gone red on an **error**, not on a fail-open, and would have proved nothing about the gate
it guards. The load-bearing assertions are the **numeric** ones, which turn the pre-fix code into a
wrong *answer* (`AUTO`). The string and `$null` cases are still pinned — a mis-typed caller now gets a
decision rather than a stack trace on both twins — but they are documented in the suites as *not* the
regression proof. Ratcheted in the root `AGENTS.md`.

## The fix

`plugin/engine/lib/risk.ps1`:

* new `Test-RiskStrictTrue` — true only for a real `[bool] $true`; every number, string, `$null` and
  object is `$false`;
* the four gate flags on `Get-PromotionDecision` are declared **untyped** (the `[bool]` annotation *is*
  the coercion) and narrowed through it into `$isGateGreen` / `$isReviewShip` / `$isE2EEvidence` /
  `$isReviewerConfigured`. Distinct names on purpose: PowerShell variables are case-insensitive, so
  `$gateGreen = … $GateGreen` would assign back to the parameter and the narrowing would be a silent
  no-op.

No sh change: `promotion_decision` was already strict (only the exact string `1` passes). The sh suite
gained matching assertions so the twins' coverage is symmetrical.

`plugin/.claude-plugin/plugin.json` 0.3.7 → **0.3.8** — a shipped engine function's signature changed,
so the version moves in the same diff (2026-08-12 ratchet).

## Reproduce

```
powershell -NoProfile -File state/evidence/2026-09-06-strict-promotion-flags/mutation-proof.ps1 -RepoRoot .
```

Recorded output: `mutation-proof.txt`. The script rebuilds the mutant from the shipped lib each run
and throws if the shipped param block no longer matches, so it cannot silently rot into a no-op.

## Gate

| suite | result |
|---|---|
| `harness/tests/run-tests.sh` | **319 / 0** (307 baseline + 12) |
| `harness/tests/run-tests.ps1` | **332 / 0** (317 baseline + 15) |
| `bash -n` over every `.sh` | clean |

`pwsh` is not installed on this box, so the numeric-coercion probe was run under Windows PowerShell
5.1 only. The fix removes binder coercion from the path altogether, so the behaviour is now
host-independent by construction; CI's pwsh job exercises the same assertions.
