# Evidence — /promote reviewer-identity wiring, end-to-end (2026-09-06)

Branch `worktree-s3-reviewer-identity`, rebased onto `main` at `8d3f218`, plugin 0.2.11 → **0.3.7**.

This is the evidence the 2026-09-05 shadow review demanded. Both judges had reviewed the wiring
against `2a6cf25..d8b5200` and split: the Fable 5.1 primary said SHIP with one should-fix ("the batch
records no evidence artifacts"), and the Codex `gpt-5.6-sol` second said REJECT with four blockers.
This batch answers all five, and the dogfooding that produced the answers turned up a sixth thing
nobody had asked about — two live fail-opens, one in the money rule and one in the reviewer gate the
batch was written to add.

## What the batch does

1. **Rebases the three unmerged wiring commits onto main.** `plugin.json` conflicted (0.2.11 vs
   0.3.5); `plugin/engine/CLAUDE.md` had become an `@AGENTS.md` shim on main, so its ratchet rule was
   rehomed into `plugin/engine/AGENTS.md`; the third commit's `fix_plan` annotation was dropped —
   main already carries a corrected one, and the branch's version repeated the claim that this wiring
   shipped in PR #9, which it did not.
2. **Drops the GitHub App installation-token claim** (Codex blocker 3) from `docs/promotion.md` and
   the schema, and says plainly why the path cannot work.
3. **Binds the decision to the PR** (Codex blocker 1) — `/promote` §1 now resolves the PR first and
   requires an open PR whose `headRefOid` is the classified HEAD and whose `baseRefName` is the
   environment's configured branch, re-checked in §8 immediately before approving.
4. **Finalises the audit record** (Codex blocker 2) — §7's record is explicitly *intent* and starts
   `"outcome": null`; a new §8a writes what actually happened, plus a second `risk-outcome` ledger row.
5. **Fixes a fail-open found while producing this evidence** — see below.
6. **Records the end-to-end evidence** (Codex blocker 4 / the primary's should-fix): this directory.

## The fail-open

Running the shipped classifier over a real range of this repo, the money rule reported **no money
vocabulary at all** in a 167 KiB diff that contains `price` 28 times, `tax` 31 times and `stripe`
twice. `money_signal` matched with `printf '%s' "$text" | grep -q`. `grep -q` exits at the first
match; printf still has ~100 KiB to write and dies of SIGPIPE; `set -o pipefail` — which `loop.sh`,
`fleet.sh` and the test suite all set — promotes printf's 141 to the pipeline's status. The match is
discarded and the term reports absent.

So on any diff past the 64 KiB pipe buffer, **every money term was invisible** and a real payments
change would have classified LOW and become auto-mergeable. That is the one rule the design says can
never fail open. Twelve unit assertions covered the rule and all stayed green, because every fixture
was a single short line that fits the buffer.

`PIPESTATUS=(141 0)` is the whole story: grep matched, printf died, pipefail returned the corpse.

Two siblings carried the same shape and are fixed with it:
- `usage_limit_error` in `lib/gate.sh` — `$out` is a whole phase transcript. Fails *closed*, but it
  silently disabled the dispatcher's cross-vendor fallback on exactly the large transcripts a real
  usage-limit failure produces.
- `fleet.sh`'s protected-path tamper guard — `$staged` on a large build. Fails **open**: a worker that
  touched `specs/` or `.claude/` would have merged.

Every site now uses a here-string (a temp file, no pipe, no SIGPIPE to lose), including the ones whose
input is always small, so nobody has to re-derive which call sites are "safe enough".

`mutation-proof.txt` shows both implementations on the same fixture. The pre-fix body returns
`LOW` / `AUTO`; the shipped one returns `HIGH` / `HUMAN`.

**The ordering in the regression fixture is load-bearing** and my first attempt got it wrong: the
money word must come FIRST, with the filler after. With the word at the end, grep has to read the
whole input before it can match, printf finishes cleanly, and the buggy code passes the test. The
first mutation run "passed" for exactly that reason and is why the fixture now leads with the match.

## Runs

| Probe | What it proves | Artifacts |
|---|---|---|
| `probe-classify.sh` | The shipped lib over five real ranges of THIS repo: LOW/MEDIUM/HIGH tiers, each with a §7 `risk.json` and a `risk` ledger row. | `probe-classify.log`, `risk/*.json`, `ledger.jsonl` |
| `probe-consumer.sh` | The same lib over a throwaway repo shaped like a consumer app — a clean LOW, a MEDIUM migration, a money HIGH by path, a money HIGH by content alone. | `probe-consumer.log`, `risk/risk-consumer-*.json`, `ledger-consumer.jsonl` |
| `probe-identity.sh` | The reviewer gate against a REAL pull request, with real `gh api user` calls, in four token states. | `probe-identity.log` |
| `mutation-proof.sh` | The money rule's fix is load-bearing. | `mutation-proof.txt` |

### Why the tier samples come from two repos

This repo self-governs: `RISK_SELF_GOVERN_GLOBS` pins any change to the harness's own policy,
guardrail or CI files to HIGH, and its promotion docs quote the money vocabulary in prose. Almost
every range here is HIGH, including this batch (`high-thisbatch`, HIGH on four self-governance paths
— which is exactly why it goes to a human). That is correct behaviour and useless as a demonstration
of a clean LOW or MEDIUM, so `probe-consumer.sh` builds a real git repo shaped like a consumer
project and classifies real commits in it with the same shipped config and lib.

### The reviewer gate

`probe-identity.sh` runs the same LOW range through the decision four times, changing only the
reviewer token:

| Token state | Resolves to | Reviewer bool | Decision |
|---|---|---|---|
| env var unset | — | false | HUMAN |
| invalid token | — (`gh api user` exits 1) | false | HUMAN |
| the PR author's own token | `James-Lloyd` (the author) | false | HUMAN |
| the separate write identity | `jl-pr-reviewer` | true | AUTO |

Only the last one may merge, and it is the only one where GitHub would accept the approval. The run
ends by re-reading the PR to show its review state never changed: the probe issues `gh api user` and
`gh pr view` only — there is no `gh pr review` and no `gh pr merge` anywhere in it.

The §1 binding on this very PR is also recorded, and it *fails* — deliberately. PR #16's head is the
classified HEAD (BOUND), but its base is `main` while `promotion.staging.branch` is `staging`
(MISMATCH). A `/promote staging` run against it can never reach AUTO. That is the new base-branch
check doing its job on a live PR.

### The second fail-open, found by this probe

The first run of the identity probe returned **AUTO for an invalid token**. `/promote` §6.3 said
`REVIEWER=$(GH_TOKEN=$tok gh api user --jq .login)` and "any failure ⇒ reviewer false", but on a bad
token `gh api user` exits non-zero *and prints its error body to stdout*:

```
exit=1
stdout: { "message": "Bad credentials", "documentation_url": "...", "status": "401" }
stderr: gh: Bad credentials (HTTP 401)
```

So the capture is non-empty, it is not equal to the author, and the natural reading of the procedure
concludes "a separate reviewer resolved" — an expired reviewer token would have produced AUTO.

§6.3 now requires **both** the zero exit status and a login-shaped result
(`^[A-Za-z0-9](-?[A-Za-z0-9])*$`), because the two failure shapes differ: a network error exits
non-zero with empty output, a 401 exits non-zero with output that parses. `probe-identity.sh`
implements both, and the log above is the corrected run. Two prose pins cover it in each suite.

Tokens are read from the local `gh` keyring into one variable, passed to one child process, and never
echoed, written or committed. Only the login each resolves to is recorded.

## Shadow mode

The shipped `harness.config.json` keeps `promotion.enabled: false`, which short-circuits every
decision to HUMAN before the tier or the reviewer gate is consulted. To exercise those arms the probes
build `probe-config.shadow.json` — the shipped config with that one flag flipped — and pass it
explicitly. The repo's own config is never written, and promotion stays off.

## Gate

| Suite | Result |
|---|---|
| `run-tests.sh` (bash) | 306 / 0 |
| `run-tests.ps1` (PowerShell 5.1) | 316 / 0 |
| `fleet-queue-test.sh` / `.ps1` | 31 / 0 each |
| `loop-review-test.sh` / `.ps1` | 16 / 0 each |
| `run.mjs` dispatcher self-test | folded into both suites |
| shell syntax check (`bash -n`, every `.sh`) | all OK |

New assertions in this batch: 9 prose pins (the PR binding, the outcome record, the retired App
claim, and the two on §6.3's exit-status requirement); 2 oversized-input regressions for
`money_signal` and `usage_limit_error`. All mirrored on both twins.

One flake worth naming: `fleet-queue-test.sh` reported 30/1 once while `run-tests.sh` was running
concurrently, and 31/0 on every isolated run of either twin. The suites contend over temp state; run
them one at a time.

## What is still human-gated

- **Merging this PR.** It classifies HIGH on self-governance, so under the harness's own policy a
  human merges it. That is the mechanism working, not an obstacle to route around.
- **A real approve + merge under the reviewer token.** The probe proves identity resolution and the
  decision; it deliberately never approves. Arming that needs `promotion.enabled: true`, the reviewer
  token in the promotion runtime, and the repo's "Allow auto-merge" setting — all listed in
  `docs/promotion.md` §3.
- **The `risk-classifier` agent has still never run inside a real `/promote` invocation.** These
  probes execute §1, §6, §7 and §9 through the shipped lib, but §4 spawns a fresh-context judge that a
  script cannot stand in for, so they pass the deterministic tier as the neutral input to the
  escalate-only `max()` — which can raise nothing and lower nothing. Running the slash command end to
  end once is carried as a follow-up on the S3 line.
