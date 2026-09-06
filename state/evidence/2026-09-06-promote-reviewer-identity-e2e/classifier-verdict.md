# `/promote` §4 — the fresh-context risk classifier, run for real on this range

The `risk-classifier` agent, spawned fresh with no knowledge of the session that produced the batch,
handed the diff and the deterministic tier for `8d3f218..HEAD`. Its only permitted moves are to
confirm or RAISE.

Pinned to Fable 5.1 by frontmatter; that spawn died on the model's usage cap, so it was re-spawned
with `model: opus` per the 2026-07-14 project rule. 20 tool uses, 241 s.

**Verdict: `RISK: HIGH`** — confirming the deterministic HIGH, and it re-derived the tier itself
rather than taking the one it was given. Verbatim result below.

Two things in it are worth carrying forward:

- It re-ran `deterministic_risk` over the *current* range and got **more** reasons than the run it was
  handed — including money signals and a 1650-line size trip. The money hits are **self-referential**:
  the evidence artifacts committed in this batch quote the money term list and the earlier classifier
  output, and `probe-config.shadow.json` carries the shipped `moneySignals` array. No payments code is
  involved. They are genuine matches under the shipped rule and they only escalate, so nothing is
  wrong — but writing evidence *about* the money rule now raises this repo's own future
  classifications, which is worth knowing before anyone reads a HIGH here as alarming.
- It named an exposure the batch's own author did not: the fixes change behaviour for **every
  consumer** on their next `/plugin update`, not just this repo. `money_signal` starting to fire past
  64 KiB flips classifications LOW→HIGH in installed repos on a cache-refresh schedule they do not
  control (fail-safe direction), and the fail-closed 8th argument makes auto-merge **silently inert**
  in any consumer that armed it without `promotion.reviewer.tokenEnv` — no error, no red, promotions
  simply all become HUMAN. Doctor check 11(g) is the only signal, and a consumer has to choose to run
  it. `plugin.json` 0.3.7 is an outbound artifact: reverting this tree does not un-ship it.

---

## Verbatim

**Deterministic tier handed to me: HIGH.** I re-ran `deterministic_risk` over the *current* full range
(worktree `plugin/engine/lib/risk.sh`, shipped `harness/harness.config.json`); it now returns **more**
reasons than the run I was given, not fewer:

```
HIGH | self-governance: harness/harness.config.json, plugin/commands/promote.md,
       plugin/engine/lib/risk.ps1, plugin/engine/lib/risk.sh
     | money signal 'price'|'amount'|'currency'|'charge'|'refund'|'payout'|'invoice'|'tax'
       |'discount'|'balance'|'stripe'|'paypal'|'adyen'|'braintree' in added lines
     | 1650 changed lines (limit 1000)
```

(The money hits are self-referential — they come from the committed evidence artifacts under
`state/evidence/2026-09-06-promote-reviewer-identity-e2e/` quoting the term list and prior classifier
output, plus `probe-config.shadow.json`'s own `moneySignals` array. No payments code. But they are
genuine matches under the shipped rule, and they only escalate.)

I confirm HIGH. Independent mechanisms, beyond the self-governance rule:

- `plugin/engine/lib/gate.sh:154` — `usage_limit_error` moves from `printf | grep -q` to a
  here-string, which **activates a previously dormant path**. Mechanism: any phase transcript over the
  64 KiB pipe buffer containing `quota`, `overloaded`, `rate limit` or a `429`-shaped string —
  including that text merely appearing *inside a diff or file the phase printed*. Damage:
  `loop.sh`/`fleet.sh` now genuinely take the cross-vendor/model fallback where for large transcripts
  they previously never did; a false positive silently reroutes an unattended phase to a different
  model and vendor. The fix is right, but this range contains no live-fire of the runner with the
  newly-live branch — the only proof is a synthetic 200 KiB fixture in the suites.
- `plugin/engine/lib/risk.sh:164` (+ the PS twin's pinning assertion) — `money_signal` semantics change
  for every consumer of the plugin. Mechanism: any diff whose added text exceeds 64 KiB. Damage:
  classifications flip LOW→HIGH across installed consumer repos the moment they `/plugin update`, on a
  cache-refresh schedule they do not control. Direction is fail-safe, but the blast radius is every
  repo running the harness, not this one.
- `plugin/engine/lib/risk.sh:304,362` and `plugin/engine/lib/risk.ps1:333,388` — breaking signature
  change on a shipped engine function (`promotion_decision` 8th arg / `-ReviewerConfigured`, default
  fail-closed). Mechanism: any consumer that has armed auto-merge and has no
  `promotion.reviewer.tokenEnv` + live token. Damage: auto-merge becomes permanently and **silently**
  inert — no error, no red, promotions simply all become HUMAN forever. That is squarely the
  silent-failure category; the only signal is the new doctor check 11(g), which a consumer has to
  choose to run. (Caller sweep is clean — `/promote` prose is the sole caller, and the version bump
  0.3.5→0.3.7 is present per the ratchet.)
- `plugin/engine/fleet.sh:239` — the fleet worker's protected-path tamper guard changes behavior for
  staged lists past the buffer (previously SIGPIPE-141 under `pipefail` reported "no protected path"
  and **merged the tamper**). Damage direction is safe, but it changes what the unattended fleet
  runner merges vs. parks, and no fleet live-fire is in this range.

Reversibility is the one place I'd temper the "trivially revertible" reading: the tree revert is clean
(no migration, no data rewrite), but `plugin/.claude-plugin/plugin.json` 0.3.7 is an **outbound
artifact** — once a consumer has pulled it, a revert here does not un-ship it and needs a forward
0.3.8.

Notes for the human, not tier-moving:

- Nothing in this range weakens a control. Every change is in the tightening direction: a new
  fail-closed reviewer gate before AUTO, PR head-SHA + base-branch binding, an outcome record, and
  three SIGPIPE fail-opens closed. No test was deleted, skipped or relaxed; the suites gain assertions
  on both twins, including oversized-input regressions with the load-bearing "marker first, filler
  after" ordering.
- Mitigating context: `harness/harness.config.json` still ships `promotion.enabled: false`, and this
  repo classifies HIGH on self-governance regardless, so no auto-merge is reachable here today. The
  exposure is entirely to consumer installs.
- The deterministic rules are **not** over-escalated here — I'd have raised this to HIGH on
  `plugin/commands/promote.md` and `risk.sh` alone.
- Carried forward in `state/fix_plan.md:105`: the `risk-classifier` agent has still never executed
  inside a real `/promote` invocation; the evidence probes fed the deterministic tier in as the max()
  identity. So §3–§5 of the policy this range rewrites remain unexercised end to end.

RISK: HIGH
