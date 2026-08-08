# Risk-gated promotion — evidence (2026-08-08)

## Gate
| Suite | Result |
|-------|--------|
| `run-tests.ps1` (PowerShell 5.1) | **219 / 0** (baseline 150) |
| `run-tests.sh` (bash + jq) | **209 / 0** (baseline 141) |
| `fleet-queue-test.ps1` | **31 / 0** |
| `fleet-queue-test.sh` | **31 / 0** |

+69 assertions on PowerShell, +68 on bash. (Not identical by one: PS carries an extra
`schema declares an enum` presence assertion, added because three PS schema assertions were found
to false-pass on key deletion — see the last section of `mutation-test.txt`.)

## Files
- `run-tests-ps.txt`, `run-tests-bash.txt`, `fleet-queue-ps.txt`, `fleet-queue-bash.txt` — the gate.
- `e2e-bash.txt`, `e2e-ps.txt` — the shipped engine driven end-to-end on a REAL diff and across the
  full decision matrix, on both twins. PART 2 matches line for line.
- `mutation-test.txt` — proof the new assertions actually fail when the code is broken.

## What the e2e demonstrates
1. **The policy refuses to auto-approve its own introduction.** This change edits
   `harness.config.json`, `lib/risk.*`, `/promote`, the classifier and the skill — all on the
   hardcoded self-governance list — so it classifies HIGH.
2. **The agent cannot lower a tier.** Feeding the classifier's lowest possible answer (`RISK: LOW`)
   against a deterministic HIGH still yields HIGH.
3. **Prod is refused before config is read**, even at LOW with everything green.
4. **Exactly one row reaches AUTO**: LOW + staging + gate green + review SHIP + e2e evidence.
   Unreviewed, red, no-evidence, migration, money-in-an-uncovered-path, and
   classifier-did-not-run all land on a human, each with a distinct reason.
5. **The content rule earns its place**: `tax_rate` in `src/cart/total.ts` pins HIGH although no
   path glob covers that file.

## Fresh-context review: fix-then-ship, 2 blockers, both fixed
An independent reviewer (opus, fresh context) found two ways the component failed OPEN. Both are
fixed and both now have mutation-verified assertions on **both** twins:

1. **The PowerShell verdict parser was case-INSENSITIVE** (`-match` defaults to it; the sh twin's
   `grep -E` does not). The classifier prompt actively invites a prose note for the human, so an
   output of `RISK: HIGH` followed by `risk: low would be wrong here` took the *prose* line as the
   last verdict and returned **LOW on PowerShell, HIGH on bash** — a tier-lowering twin divergence,
   i.e. a direct breach of the escalate-only invariant. Fixed with `-cmatch`.
2. **A malformed `promotion` block failed open to AUTO.** Nothing shape-checked the block at runtime,
   and every degenerate shape *skipped a rule* rather than escalating: absent `preconditions` (still
   schema-valid, and `/harness-prune` may trim it) reached AUTO with a red gate, no review SHIP and no
   e2e evidence while the audit string read *"all preconditions met"*; `alwaysHuman` written as a
   scalar made a payments diff classify LOW; and `enabled: "false"` as a string read as ON under
   PowerShell. Fixed with `Test-PromotionConfigShape` / `promotion_config_shape`, called before any
   rule is trusted, plus `required` arrays in the schema.

Should-fixes also applied: bash now TRIMS whitespace instead of deleting it (`tr -d '[:space:]'` made
`"st aging"` match staging in bash but not PS); the three false-passing PS schema assertions now check
presence before content; the schema's `moneySignals` description was the last surface still describing
the superseded whole-word rule.

## Two real bugs the e2e caught that the unit tests did not
- **O(files x globs) fork storm.** Compiling a glob per file per rule spawned ~5600 subprocesses on a
  57-file diff; `/promote` exceeded a 2-minute timeout. Fixed by compiling one union regex per rule
  group (`globs_union_regex` / `Get-GlobUnionRegex`): 120s+ -> 17.8s in bash, trivial in PS.
- **The money rule missed `tax_rate`.** The original trailing-boundary regex excluded `_`, so it
  failed on snake_case and inflected forms (`tax_rate`, `taxes`, `prices`) — i.e. it silently passed
  real money diffs as LOW, the one direction that must never fail open. Rule changed to word-START
  matching; tests and the skill updated to the corrected contract.
