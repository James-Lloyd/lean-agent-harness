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

### 1. Bind to the PR, then resolve the range
A promotion decision is about **one specific pull request**, so resolve that PR first and pin the
classified range to it. Classifying a local range and then merging whatever PR happens to be open is
the failure this step exists to prevent — the tier would describe one tree and the merge would land
another.

Run the §9 probes first, then:
```
gh pr view --json number,state,headRefOid,baseRefName,author
```
Three bindings must hold. **Any miss ⇒ HUMAN**, recorded as *PR binding failed: <which>* (a binding
miss is a precondition failure, not a risk tier — say so):
- **Exactly one OPEN PR for this branch.** No PR, a closed/merged one, or an ambiguous match ⇒ HUMAN.
- **`headRefOid == $(git rev-parse HEAD)`.** The PR's head must be the commit you are about to
  classify. If someone pushed while you were classifying, the tier you computed no longer describes
  the PR ⇒ HUMAN.
- **`baseRefName == promotion.<env>.branch`** from `harness.config.json` (`staging.branch` for
  `staging`, `prod.branch` for `prod`). Anything else ⇒ HUMAN. Without this check a `staging`
  promotion could approve and merge a PR whose base is `main`: "prod is never automated" bypassed
  through the PR's target branch rather than through this command's environment argument.

Carry `number` and `headRefOid` forward. §7 records both, and §8 acts on **that PR number** — never
on "the current branch's PR" resolved a second time.

Then the range, measured against the PR's own base. Same ladder as `/review`, and for the same
reason (a bare `git diff` misses committed hunks):
```
BASE=$(git merge-base HEAD "origin/$BASE_REF" 2>/dev/null || git rev-parse HEAD~1)
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

   **Check the exit status, and do not treat a non-empty capture as success.** On a bad or expired
   token `gh api user` exits non-zero but prints its error body to **stdout**, so `$REVIEWER` ends up
   holding `{ "message": "Bad credentials", ... }` — a non-empty string that is not the author, which
   a naive reading turns into "a separate reviewer resolved" and then into AUTO. Observed live on
   2026-09-06 while dogfooding this section. So: keep the exit status, require it to be zero, **and**
   require the captured login to look like one (`^[A-Za-z0-9](-?[A-Za-z0-9])*$`, no whitespace, no
   braces). Either check failing ⇒ reviewer **false**, reason *reviewer identity could not be
   resolved*. Two checks rather than one because the shapes fail differently: a network error gives a
   non-zero exit with empty output, a 401 gives a non-zero exit with output that parses.

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

What §7 records is **intent**: the decision the function returned, before anything was attempted.
What actually happened is a separate field, written by §8a after acting. Never let one field carry
both — a record that says `AUTO` and stops is indistinguishable from a merge that succeeded.

Write `state/evidence/<task-id>/risk.json`:
```json
{ "range": "<BASE>..<HEAD>", "environment": "staging|prod",
  "pr": { "number": 0, "headRefOid": "<sha, == HEAD>", "baseRefName": "<the configured target>" },
  "deterministicTier": "LOW|MEDIUM|HIGH", "deterministicReasons": ["..."],
  "classifierTier": "LOW|MEDIUM|HIGH", "classifierProof": "<its escalation lines, verbatim>",
  "finalTier": "LOW|MEDIUM|HIGH",
  "preconditions": { "gateGreen": true, "reviewShip": true, "e2eEvidence": true },
  "reviewerConfigured": true, "reviewerIdentity": "<the reviewer login, never its token>",
  "decision": "AUTO|HUMAN", "reason": "<the decision function's reason string>",
  "changedFiles": ["..."], "changedLines": 0,
  "outcome": null }
```
`outcome` starts `null` and is filled in by §8a. A record left with `outcome: null` means the run
died mid-act — treat it as unresolved, never as a completed AUTO.

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
2. **Re-check the binding immediately before approving.** Time passed during §4's classifier run, so
   re-read `gh pr view <n> --json headRefOid,baseRefName,state` and require the same three bindings
   §1 established (open, `headRefOid` still `== HEAD`, base still the configured target). A push
   landed since classification ⇒ HUMAN, reason *PR moved after classification*. Never approve a head
   you did not classify.
3. Approve and merge **as the reviewer identity**, on the PR number carried from §1, scoping its
   token to only these two calls: `GH_TOKEN=$tok gh pr review <n> --approve` then
   `GH_TOKEN=$tok gh pr merge <n> --auto --squash`.
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

### 8a. Finalise the record with what actually happened
§7 recorded the *intended* decision. Now record the *outcome*, on **every** path — AUTO that merged,
AUTO that failed at approve, AUTO that approved but could not merge, and plain HUMAN. Without this
the durable record says `AUTO` for a promotion that never landed, which is exactly the attribution
failure the audit trail exists to prevent.

Fill in `outcome` in the same `risk.json`:
```json
"outcome": { "approved": true, "merged": false, "actual": "AUTO|HUMAN",
             "error": "<verbatim gh failure, or null>" }
```
`actual` is what the run really did, and it can differ from `decision`: an AUTO whose approve or
merge failed ends as `"actual": "HUMAN"` with the failure in `error`, because that is what a human
now has to finish. Then append a second ledger line so the run log carries the same fact:
```json
{"iter":0,"result":"risk-outcome","tier":"LOW","decision":"AUTO","actual":"HUMAN","approved":true,"merged":false,"env":"staging"}
```
Never overwrite the first ledger line — intent and outcome are two rows, and the pair is the trail.
Redact nothing but the token; a failure reason with no detail is not an audit record either.

### 9. Probe failures are HUMAN, not merge
Before any `gh` call (including the §1 binding and the §6 identity resolution), probe: `gh --version`,
`gh auth status`, and that a PR exists for this branch (`gh pr view --json number`). Any failure ⇒ the
HUMAN path, saying which probe failed. `gh` missing or unauthenticated is the common one, and it must
never degrade into "classify locally and merge anyway" — there is no merge without a resolved PR.

**GitHub rejects self-approval.** §6 pre-empts this by requiring the reviewer login to differ from the
author before AUTO is even possible. If a self-approval rejection still surfaces at approve time
(e.g. the env var was pointed at the author's own token), treat it as HUMAN and say so plainly; never
fall through to `gh pr merge` on an approval that did not land.

## Output
The final tier, the decision, and every reason that produced it — the same content as the audit
record, in a form a human can read in ten seconds. If the decision was HUMAN, say precisely what a
human now needs to do.
