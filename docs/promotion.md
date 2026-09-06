# Risk-gated promotion

How the harness decides whether a change can merge to staging without a human, and why prod never
can. Operator guide; the **policy** lives in the `risk-tiering` skill and the **procedure** in
`/promote` — this file is the rollout, the wiring, and the things that will bite you.

Off by default (`promotion.enabled: false`). A `/plugin update` cannot switch it on.

## The shape

```
green gate  ->  /review SHIP  ->  /promote <env>
                                      |
                        1. deterministic rules (engine, lib/risk.*)   -- can only RAISE
                        2. risk-classifier agent (fresh context)      -- can only RAISE
                                      |
                             final tier = max(1, 2)
                                      |
                 LOW + staging + preconditions met  ->  approve + auto-merge
                 anything else                      ->  human, with the reasons
                 prod                               ->  human, always
```

Two things make this different from "ask a model whether the change is risky":

- **The first stage is not a model.** It is objective criteria computed from the diff — size,
  paths, and the money vocabulary in the added lines. A change cannot be talked out of its tier, and
  its author (human or agent) cannot classify it.
- **Nothing can lower a tier.** The merge is a real `max()`. The agent's job is to catch what the
  path globs miss, not to grant exceptions.

## Turning it on

### 1. Shadow mode first

Do not hand it the merge button on day one. Set `enabled: true` but
`staging.autoMergeAtOrBelow: null`. `/promote` then classifies, writes the audit record, and posts
the comment — but always returns HUMAN. You merge by hand, and compare your judgement to its tier.

Run that until the disagreements are boring. When you flip to `"low"`, you are granting a mechanism
you have already watched.

### 2. Tune `alwaysHuman` to YOUR money paths

The shipped globs (`**/payments/**`, `**/billing/**`, `**/checkout/**`, …) are a starting guess.
A glob that matches nothing is indistinguishable from no policy at all, so check:

```
git ls-files | grep -Ei 'payment|billing|checkout|invoice|price|payout|ledger|refund'
```

Every directory that comes back should be covered. `/harness-doctor` check 11(b) will warn when it
finds money-shaped paths your globs miss, but it cannot know your domain's names for things.

### 3. Give the approver a separate identity

**GitHub rejects self-approval.** If the token that opens the PR is the token that calls
`gh pr review --approve`, the approval fails — always, not intermittently. Auto-approval therefore
needs a second identity with **write** access to the repo: a machine user or a second account,
holding a fine-grained PAT.

**Not a GitHub App installation token.** `/promote` identifies the reviewer with `gh api user`
(`GET /user`), and GitHub documents that endpoint for user access tokens and PATs only — an
installation token gets `Resource not accessible by integration`. The identity step would fail, the
reviewer boolean would be false, and every promotion would drop to HUMAN. It fails *closed*, so it
is safe, but it is also inert: do not wire an App installation token here expecting auto-merge.

You wire it in one place — a config key naming the environment variable that holds that identity's
token:

```json
"promotion": {
  "reviewer": { "tokenEnv": "HARNESS_PROMOTE_REVIEWER_TOKEN" }
}
```

At AUTO time `/promote` reads that variable and runs *only* the two approve/merge calls with it:
`GH_TOKEN=$tok gh pr review --approve` then `GH_TOKEN=$tok gh pr merge --auto --squash`. Everything
else — the diff, the classifier, the PR the author opened — still runs under the ambient identity.

Two guards make this fail safe, both in the tested decision function, not in prose:

- **Not configured ⇒ HUMAN.** If the named variable is empty/unset, the decision's reviewer boolean
  is false and a LOW change that met every other condition still goes to a human. The failure mode of
  getting this wrong is "nothing auto-merges", not "things merge unapproved".
- **Reviewer == author ⇒ HUMAN.** Before approving, `/promote` resolves the reviewer token's login
  (`gh api user`) and the PR author, and refuses AUTO if they match — pre-empting the self-approval
  rejection instead of discovering it at approve time.

Setting it up in a repo (do this once, and keep the token OUT of the committed config — the config
only names the variable):

1. Create the reviewer account/machine user and add it as a **write** collaborator.
2. Generate a fine-grained PAT for it (Contents + Pull requests: write). Put it in the promotion
   runtime as `HARNESS_PROMOTE_REVIEWER_TOKEN` — a CI secret for the headless/nightly path, or your
   shell env for an interactive run. Not an App installation token, per the note above.
3. Turn on the repo's **Settings → General → Allow auto-merge** (else `gh pr merge --auto` errors).
4. In an interactive Claude session the auto-mode classifier blocks the write-ish `gh` calls —
   `gh pr merge`, `gh pr review`, and the reviewer-identity probe `gh api user` (blocking that last
   one silently makes the feature *inert*: reviewer resolution fails ⇒ HUMAN). Allowlist those three
   in `.claude/settings.json`, or run `/promote` on the headless path.

## What the tiers mean

See `plugin/skills/risk-tiering/SKILL.md` — the tier table, the full criteria list, and the
hardcoded self-governance paths live there, and the twin self-tests pin them to config. Restating
them here would create a second copy to go stale.

The short version: **LOW** is "nothing tripped"; **MEDIUM** is size or a sensitive surface;
**HIGH** is money, irreversibility, or a weakened control. Only LOW, only staging, only with a green
gate + a review SHIP + e2e evidence.

## The audit trail

Every run writes the record *before* it acts, whether the outcome is AUTO or HUMAN:

- `state/evidence/<task-id>/risk.json` — the range, the PR it is bound to (number, head SHA, base
  branch), both tiers, every rule that fired, the classifier's proof text, the preconditions, the
  decision and its reason.
- one `{"result":"risk", …}` line in `harness/.runs/<runId>/ledger.jsonl`.
- a structured PR comment, criterion by criterion.

Then, after acting, it writes what actually happened — the `outcome` object in the same `risk.json`
and a second `{"result":"risk-outcome", …}` ledger line, on every path. Intent and outcome are two
records because they genuinely differ: an AUTO whose approve call fails ends as a HUMAN, and a
record that stopped at `"decision": "AUTO"` would claim a merge that never happened. A `risk.json`
still carrying `"outcome": null` means the run died mid-act; it is unresolved, not a completed AUTO.

The point is attributability after the fact: for any merge, you can reconstruct which signals the
decision used, which PR head they described, and whether the approval actually landed. A bare
"approved by automation" is not an audit trail.

**The decision is bound to the PR.** `/promote` resolves the PR first and refuses to act unless its
head commit is the one classified and its base branch is the environment's configured target. That
is what stops a `staging` run from approving a PR aimed at `main`, or from merging a head that was
pushed after the classifier ran.

## Governance: changing the policy is not a config tweak

Changing the criteria, the thresholds, or the classifier's prompt changes what ships without a
human. Three mechanisms make that deliberate rather than incidental:

1. **The self-governance list is hardcoded** in `lib/risk.*`, not config. A diff touching
   `harness.config.json`, the risk lib, the classifier agent, `/promote`, the risk-tiering skill,
   `.claude/settings.json`, the hooks, or `.github/workflows/` is pinned **HIGH**. The policy cannot
   auto-approve a change to itself.
2. **Widening automation past LOW is a schema change.** `staging.autoMergeAtOrBelow` has no
   `medium` member and `prod.autoMerge` is `const false`. Automating prod is not a value you can
   set; it is a code change with a review.
3. **The twin self-tests assert all of the above** and go red if any of it becomes expressible.

Treat a model swap for the classifier the same way — it is a policy change, not a tuning change.

## Failure modes, all of which are HUMAN

`gh` missing or unauthenticated · no PR for the branch · **the PR's head is not the classified
commit** · **the PR targets a branch other than the environment's configured one** · **no separate
reviewer identity configured (`reviewer.tokenEnv` empty/unset)** · **the reviewer identity equals the
PR author** · self-approval rejected · the classifier could not run · an unparseable `RISK:` line ·
an empty diff · any unmet precondition · an unknown environment · `enabled: false`.

None of them merge. If you ever see a promotion path that fails toward the merge, that is a bug and
a `/ratchet` rule.

## Related

- `/promote` — the command.
- `plugin/skills/risk-tiering/SKILL.md` — the policy SSOT.
- `plugin/agents/risk-classifier.md` — the fresh-context judge.
- `/harness-doctor` check 11 — validates the block.
- `docs/overnight.md` — the ledger decode table, including the `risk` row.
