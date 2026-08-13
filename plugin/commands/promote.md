---
description: Classify the risk of promoting the current change to staging or prod, then auto-approve + auto-merge only a LOW-risk staging promotion. Medium, high, money-touching, and all prod promotions go to a human.
argument-hint: staging | prod
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill
---

# /promote — risk-gated promotion

Target environment: **$ARGUMENTS** (required — `staging` or `prod`; if absent, ask, do not guess).

Read the `risk-tiering` skill first — it is the single source of truth for what each tier means and
which criteria escalate. This command is the *procedure*; the skill is the *policy*.

The shape of this is deliberate and taken from two places: risk is decided by **objective criteria
computed from the diff, never self-declared** by whoever wrote the change (Ona), and every automated
approval is **logged with the signals it used** so any decision is attributable after the fact
(Anthropic's AI-native SDLC). You are executing a policy, not forming an opinion.

## Non-negotiables

- **Prod is never automated.** For `prod` you classify, report, and hand to a human. There is no
  branch of this command that merges to prod. `Get-PromotionDecision`/`promotion_decision` refuses it
  before it reads config, and the schema pins `promotion.prod.autoMerge` to `const false`.
- **You never lower a tier.** The deterministic engine runs first, the classifier agent second, and
  the result is the *maximum*. If you find yourself reasoning toward "this is probably fine
  actually", stop — that reasoning has no output channel here.
- **Fail closed.** Anything unresolvable — no PR, `gh` unauthenticated, an unparseable verdict, an
  empty diff, a missing precondition — takes the HUMAN path. Never the merge path.

## Procedure

### 1. Resolve the range
Same ladder as `/review`, and for the same reason (a bare `git diff` misses committed hunks):
```
BASE=$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD~1)
```
If `BASE == HEAD`, fall back to `git rev-parse harness-reviewed`. If that is also missing or equal,
**stop and ask the human for a range** — never promote an empty diff.

### 2. Check the preconditions (fail-closed, before any classification)
Risk classification decides how much scrutiny a *good* change needs; it never substitutes for the
gate or the review. Per `promotion.preconditions` in `harness.config.json`:
- **gateGreen** — the full project gate is green on this range (run `/verify` if you do not have a
  fresh result; a stale green is not a green).
- **reviewShip** — a fresh-context `/review` SHIPped this range: `git merge-base --is-ancestor HEAD
  harness-reviewed` succeeds, i.e. the watermark covers HEAD. The risk classifier is **not** the
  reviewer and does not substitute for one.
- **e2eEvidence** — captured evidence exists for this range under `state/evidence/`.

Record which ones passed. A miss does not stop the command — it forces HUMAN, and the audit record
must say *precondition unmet*, not *risk too high*. Those are different failures.

### 3. Deterministic tier
Source the engine lib and run it. PowerShell:
```
. "${CLAUDE_PLUGIN_ROOT}/engine/lib/risk.ps1"
$cfg = Get-Content harness/harness.config.json -Raw | ConvertFrom-Json
$sig = Get-DiffSignals $BASE HEAD
$det = Get-DeterministicRisk -Config $cfg -Files $sig.Files -ChangedLines $sig.ChangedLines -AddedText $sig.AddedText
```
bash (`diff_signals` writes the two temp files and echoes the changed-line count):
```
source "${CLAUDE_PLUGIN_ROOT}/engine/lib/risk.sh"
LINES=$(diff_signals "$BASE" HEAD /tmp/promo-files /tmp/promo-added)
deterministic_risk harness/harness.config.json "$LINES" /tmp/promo-files /tmp/promo-added
```
Keep the full reason list. It is what the PR comment and the audit record are made of.

### 4. Fresh-context classifier
Spawn the `risk-classifier` agent (`Agent`), handing it the diff, the changed file list, the
deterministic tier, and the rules that fired. Route per `models.review` — if that phase resolves to
`codex`, dispatch the codex lib **read-only** via Bash instead of spawning the subagent, exactly as
`/review` does, and afterwards `git status` and revert anything unexpected.

Parse its output with `Get-RiskVerdict` / `risk_verdict`. Do not eyeball it — the parser's
last-`RISK:`-line rule and its fail-closed HIGH default are the contract.

If the agent fails to run at all (usage cap, unavailable), re-spawn once on the phase fallback per
the routing rules. If it still cannot run, the tier is **HIGH** — a classifier that did not run has
not cleared anything.

### 5. Merge the tiers (for the audit record)
`Merge-RiskTier` / `risk_tier_max` gives `finalTier` for the record below. This is a max(), so the
agent can only have raised it. The decision function (§6) recomputes this same merge internally from
the two tiers you pass it — you cannot hand it a lower pre-merged tier — so the recorded `finalTier`
and the actual decision can never diverge.

### 6. Resolve the reviewer identity, then decide
Auto-merge approves the PR, and **GitHub rejects self-approval** — so AUTO is only reachable when a
*separate* write identity is available to approve. Resolve it FIRST (it is an input to the decision,
which is in turn an input to the record in §7), and reduce it to one boolean; if any step below
fails, the boolean is **false** and the decision drops to HUMAN.

1. Read the env-var name from config: `promotion.reviewer.tokenEnv`. Absent/empty ⇒ reviewer
   **false** (reason for the record: *reviewer identity not configured*).
2. Read the token from that variable — bash `TOK="${!VAR}"`, PowerShell
   `$tok = [Environment]::GetEnvironmentVariable($VAR)`. Empty/unset ⇒ reviewer **false**. **Never
   echo the token, never write it to `risk.json`, the ledger, or a PR comment.**
3. Resolve the two identities and require they differ:
   `REVIEWER=$(GH_TOKEN=$tok gh api user --jq .login)` and
   `AUTHOR=$(gh pr view <n> --json author --jq .author.login)` (author resolved with the *ambient*
   token, not the reviewer token). Any failure, or `REVIEWER == AUTHOR` ⇒ reviewer **false** (reason:
   *reviewer identity equals author*). This pre-empts the self-approval rejection instead of
   discovering it at approve time.

Then call `Get-PromotionDecision` / `promotion_decision` with the environment, the **deterministic
tier and the classifier tier as two separate arguments** (PS `-DeterministicTier`/`-ClassifierTier`;
bash positional `$3`/`$4`), the three precondition booleans, and **the reviewer boolean** (PS
`-ReviewerConfigured`; bash positional `$8`). Do NOT pre-merge the tiers yourself and do NOT
re-derive the decision by hand — the function computes the escalate-only max() internally (so a
hand-picked lower tier cannot slip through) and encodes the prod refusal, disabled-by-default, and
no-reviewer-identity refusals. An unknown/omitted classifier tier ranks HIGH and an absent/false
reviewer boolean drops to HUMAN — both fail closed. Keep the returned Decision and Reason for §7/§8.

### 7. Write the audit record BEFORE acting
Every automated approval must be attributable after the fact, so the record is written whether the
outcome is AUTO or HUMAN, and it is written *first* (before §8 acts).

Write `state/evidence/<task-id>/risk.json`:
```json
{ "range": "<BASE>..<HEAD>", "environment": "staging|prod",
  "deterministicTier": "LOW|MEDIUM|HIGH", "deterministicReasons": ["..."],
  "classifierTier": "LOW|MEDIUM|HIGH", "classifierProof": "<its escalation lines, verbatim>",
  "finalTier": "LOW|MEDIUM|HIGH",
  "preconditions": { "gateGreen": true, "reviewShip": true, "e2eEvidence": true },
  "reviewerConfigured": true, "reviewerIdentity": "<the reviewer login, never its token>",
  "decision": "AUTO|HUMAN", "reason": "<the decision function's reason string>",
  "changedFiles": ["..."], "changedLines": 0 }
```
Then append one line to the current run's `harness/.runs/<runId>/ledger.jsonl` (newest run dir; if
there is no run in progress, create `harness/.runs/promote-$(date +%Y%m%dT%H%M%S)/`):
```json
{"iter":0,"result":"risk","tier":"LOW","decision":"AUTO","env":"staging","path":"claude","usedFallback":false}
```

### 8. Act
**On `AUTO`** (only ever reachable for staging + LOW + all preconditions met + `promotion.enabled` +
a resolved separate reviewer identity):
1. Post a structured comment on the PR, criterion by criterion — each check, whether it passed, and
   why (name the reviewer identity, never its token). A bare "approved by automation" is not an audit
   trail.
2. Approve and merge **as the reviewer identity**, scoping its token to only these two calls:
   `GH_TOKEN=$tok gh pr review <n> --approve` then `GH_TOKEN=$tok gh pr merge <n> --auto --squash`.
   **Re-read the token from its env var in the SAME shell invocation as these two calls** — shell
   state does not survive between separate command runs, so a `$tok` captured back in §6 is empty
   here and the approve would silently run unauthenticated. If the approve call does not succeed,
   STOP — take the HUMAN path and never run the merge. (`--auto` also requires the repo's "Allow
   auto-merge" setting to be on; if merge reports it is disabled, say so and leave the PR approved
   for a human to merge.)

**On `HUMAN`** (everything else):
1. Post the same structured comment, headed **ESCALATED**, naming exactly which criteria tripped or
   which precondition was unmet (including *reviewer identity not configured / equals author* when
   that was the cause).
2. Label the PR `risk:medium` / `risk:high`, plus `needs-human`.
3. Append to `state/handoff.md` under `## Needs human decision`, with the range and the reasons.
4. **Do not merge. Do not approve.** Not even "it's obviously fine" — that judgement is the thing
   this command exists to remove.

### 9. Probe failures are HUMAN, not merge
Before any `gh` call (including the §6 identity resolution), probe: `gh --version`, `gh auth status`,
and that a PR exists for this branch (`gh pr view --json number`). Any failure ⇒ the HUMAN path,
saying which probe failed.

**GitHub rejects self-approval.** §6 pre-empts this by requiring the reviewer login to differ from the
author before AUTO is even possible. If a self-approval rejection still surfaces at approve time
(e.g. the env var was pointed at the author's own token), treat it as HUMAN and say so plainly; never
fall through to `gh pr merge` on an approval that did not land.

## Output
The final tier, the decision, and every reason that produced it — the same content as the audit
record, in a form a human can read in ten seconds. If the decision was HUMAN, say precisely what a
human now needs to do.
