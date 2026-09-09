# 2026-09-09 — V6.1: this repo's second reviewer is the Codex CLI

**Verdict: GREEN.** Both probes pass. The claim this dir supports:

> `models.review.second: "codex"` in `harness/harness.config.json` reaches the real Codex CLI, at the
> model and depth `review.codex` declares, read-only and unable to escalate — and the loop's review
> point consults it only after the Claude primary ships, recording both verdicts.

Measured on **codex-cli 0.153.4**, ChatGPT auth (`codex login status` → "Logged in using ChatGPT",
`CODEX_API_KEY` unset). Effective Codex model **`gpt-5.6-sol`** — the CLI's default, because the
config deliberately pins none (every `*-codex` ID was retired; design-doc 002 Consequences). That ID
is what the CLI reported on this date, not a value the harness chose; re-read it from a transcript
header rather than trusting this line on a later version.

## What each file is

| File | What it shows |
|---|---|
| `routing-live-fire.txt` | Arms A–D: the shipped resolvers over the REAL config, a negative control, one real `codex exec`, and the shipped builder's argv |
| `second-reviewer-transcript.log` | Arm C's transcript — the CLI's own header: `approval: never`, `sandbox: read-only`, `reasoning effort: high` |
| `loop-second-reviewer.txt` | Arm E: a real `loop.sh --mode auto` review point with a stubbed Claude primary and the REAL Codex second |
| `arm-e-loop.out` | That loop run's console output |
| `arm-e-second-transcript.log` | The second judge's own transcript from inside the loop |
| `probes/*.sh` | Re-runnable. `PROBE_SKIP_MODEL=1` skips every paid arm; `PROBE_OUT_DIR` redirects all output |

## Why arm E exists at all

PR #23 (2026-09-09) live-fired a codex **primary** reviewer through the loop. `second_review()` /
`Invoke-SecondReview` — the function this slice actually turns on — had **never** been run against a
real CLI. Arm E is the first time it has. The ledger from that run:

```
{"iter":1,"result":"green","path":"claude","usedFallback":false}
{"iter":1,"result":"review","path":"claude","model":"primary-judge","verdict":"SHIP"}
{"iter":1,"result":"review-second","path":"codex","model":"codex","verdict":"SHIP"}
```

The arm's Claude stub **refuses** to answer for any model but the implementer and the primary judge,
so a second opinion arriving through Claude fails the arm loudly instead of passing quietly as a
"second reviewer" that is really the same vendor twice.

## The defect this slice found

Routing the second reviewer surfaced a spec/prose defect in **four surfaces**: `harness.schema.json`
(×2), `/harness-doctor` check 10(f) and 10(g), and the model-routing skill all said the per-phase
`codex{}` block is read "only when the phase's `model` or `fallback` is codex". It is also read when
`second.model` is codex — `loop.sh:205` passes `REVIEW_CODEX_MODEL`/`REVIEW_CODEX_EFFORT` to the
second judge. So `/harness-doctor` 10(g) would have warned "unread key" about `review.codex` in
exactly the configuration the model-routing skill recommends as Codex's first use.

Arm E measures the corrected claim rather than asserting the corrected prose: its fixture sets the
**global** `models.codex.reasoningEffort` to `medium` and `review.codex.reasoningEffort` to `high`,
and the second judge's own header reads `reasoning effort: high`.

Both suites gained three mirrored assertions pinning it (`gpt-second` vs `gpt-global` sentinels), so
the prose cannot drift back without a red gate.

## Negative controls

- Arm B builds a fixture with `review.second` deleted and `review.codex.reasoningEffort` set to
  `low`, and asserts the resolvers return the *other* answer — so arm A's greens are measurements,
  not formalities (ratchet 2026-09-09: a probe that reports a verdict must be shown reporting the
  other one).
- Arm C asserts the transcript **carries a header at all** before asserting anything about its
  contents; without that, a missing header would make every check below it vacuously green.
- Arm D asserts `-m` is **absent** because the config pins no model, and carries the opposite branch
  for a config that does pin one.
- `routing-live-fire.sh` greps its own scrubbed log for the OS username and fails if it survives.

## What this does NOT show

- **Gating consequences.** Every judge in these runs shipped. The failure paths — a second judge that
  REJECTs, or one that cannot run (both stop the loop for a human, by design; there is no fallback)
  — are covered by the suites, not live-fired here.
- **Guardrail parity under Codex.** The generated `.codex/hooks.json` is still not loaded by headless
  `codex exec`; a `--user` install plus trust is the only path, and that probe is still open in
  `fix_plan`. The second judge is read-only and approval-never, which is what protects the tree here.
- **Cost or latency.** Not measured. Nothing in this dir licenses a figure about either.
