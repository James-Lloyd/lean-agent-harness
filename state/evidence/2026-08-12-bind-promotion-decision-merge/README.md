# Evidence — bind the escalate-only merge INSIDE the promotion decision

Task (state/fix_plan.md): *(should-fix, low) Bind the escalate-only merge INSIDE
`Get-PromotionDecision`/`promotion_decision`* — done when the decision takes the deterministic
signals + the classifier verdict and computes `max()` itself, so a caller cannot pass a hand-picked
tier.

## The defect being closed
Before this change, `Get-PromotionDecision`/`promotion_decision` took a single, already-merged
`Tier`. The escalate-only `max(deterministic, classifier)` was computed in `/promote`'s prose (§5)
and the *result* handed to the decision. A caller that skipped or mis-computed the merge could pass a
low tier while the true risk was higher, and the function would happily AUTO it. The merge was real
but *using* it was enforced only by prose.

## The change
The single tier argument is replaced by **two** — the deterministic tier and the classifier tier —
and the function computes the merge itself:

- `plugin/engine/lib/risk.ps1` `Get-PromotionDecision`: `-DeterministicTier` + `-ClassifierTier`,
  `$t = Merge-RiskTier $DeterministicTier $ClassifierTier`.
- `plugin/engine/lib/risk.sh` `promotion_decision`: positional signature is now
  `$1 config $2 env $3 deterministicTier $4 classifierTier $5 gate $6 ship $7 e2e`;
  `risk_rank "$(risk_tier_max "$dtier" "$ctier")"`.
- `plugin/commands/promote.md` §5/§7: `/promote` now passes **both** tiers and does not pre-merge;
  the recorded `finalTier` (still `Merge-RiskTier` for the audit record) can no longer diverge from
  the decision, which recomputes the same max() internally.
- Because `Get-RiskRank`/`risk_rank` rank any unknown input HIGH, an **omitted or garbage classifier
  tier fails CLOSED to HUMAN** — a caller cannot drop the classifier to reach AUTO.

No behavior change for a correct caller: `/promote` already computed the same max().

## Verification
- `run-tests-ps.txt` — PowerShell 5.1: **234 passed, 0 failed** (was 229; +5 merge assertions)
- `run-tests-bash.txt` — bash (jq 1.8.2): **224 passed, 0 failed** (was 219; +5 merge assertions)

The 5 new assertions per twin pin: det LOW + classifier HIGH => HUMAN (cannot bypass the classifier);
det HIGH + classifier LOW => HUMAN (deterministic escalation kept); det LOW + classifier LOW => AUTO;
and empty / garbage classifier => HUMAN (fail-closed).

## Mutation proof (`mutation-proof.txt`)
On a scratchpad copy of `risk.sh` (repo untouched), the merge was mutated to ignore the classifier
(`risk_tier_max "$dtier" "$ctier"` -> `"$dtier" "$dtier"`):

- **Real** code: `det=LOW classifier=HIGH -> HUMAN`; `det=LOW classifier='' -> HUMAN`;
  `det=LOW classifier=LOW -> AUTO`.
- **Mutant**: `det=LOW classifier=HIGH -> AUTO` — the classifier bypass the new tests are written to
  catch. The "det LOW + classifier HIGH => HUMAN" and fail-closed assertions redden under this mutant.
