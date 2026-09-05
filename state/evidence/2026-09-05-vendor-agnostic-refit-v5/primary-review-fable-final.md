# Primary judge — `reviewer` subagent, `claude-fable-5-1` @ high (agent frontmatter), fresh context

Spawned via the Agent tool with the same prompt as the second judge (`review-prompt.txt`). 20 tool uses,
477 s, ~51k subagent tokens. Verbatim final report:

---

Review complete. I inspected the full diff (2a6cf25..d8b5200), read the twin engine files, tests, schema, doctor, and promote prose at the batch head, swept sibling surfaces for stale facts, and re-ran the bash suite live on the extracted batch tree.

## What the batch does
Wires a fail-closed "separate reviewer identity" gate into the promotion decision: `promotion.reviewer.tokenEnv` (schema + shipped config), a new fail-closed-by-default 8th parameter on `Get-PromotionDecision`/`promotion_decision`, /promote prose that resolves the reviewer token, requires reviewer != author, and scopes `GH_TOKEN` to the two approve/merge calls only, doctor check 11(g), docs, +5 twin test assertions each side, plugin version bump 0.2.10 → 0.2.11, and a new engine ratchet rule.

## Verification performed
- **Bash suite run live on the batch tree: 229 passed, 0 failed** — matches the claimed `bash 229/0`. (PS suite could not be executed from this session — the worktree-isolation hook refuses `powershell` invocations here — but the PS twin's diff is line-for-line parallel to the verified bash side, reason strings are byte-identical across twins, the new assertions mirror exactly, and CI runs both hosts.)
- **Twin parity holds**: identical gate ordering (reviewer check is the last gate before AUTO in both), identical HUMAN/AUTO reason strings, sh `$8 reviewerConfigured` header comment updated in the same diff (and a ratchet rule added for that class).
- **Fail-closed confirmed in code and pinned in tests both sides**: PS default `$false`, sh `"${8:-0}"`; omitted-arg → HUMAN is asserted, so every stale caller drops to HUMAN, never to merge.
- **Guardrails clean**: no test weakened (existing assertions gained `-ReviewerConfigured $true`/trailing `1` out of necessity, and the new gate gets its own dedicated pins including the omitted-arg case); `specs/` untouched; no token or secret committed (config names only the env var, and both tests pin that); version bumped per the 2026-08-12 ratchet for an engine-lib signature change.
- **Cross-surface sweep** (per the consolidated grep-the-literal ratchet): promote.md section renumbering (§6–§9) is internally consistent; `docs/design-docs/001-risk-gated-promotion.md` and `plugin/skills/risk-tiering/SKILL.md` already describe the reviewer-identity requirement by pointer to `docs/promotion.md`, so nothing went stale; no other caller of the decision function exists.
- **Nice catch encoded in prose** (`plugin/commands/promote.md:143-146`): the "re-read the token in the SAME shell invocation" warning closes a real silent-failure mode (shell state not surviving between command runs), and merge-after-failed-approve remains forbidden.

## Findings
1. `state/fix_plan.md:468` — **should-fix** — the annotation claims "mutation-verified both runners; PS 239/0, bash 229/0" but the batch records no evidence artifacts (no run-tests output or mutation proof under `state/evidence/`), unlike every prior promotion change (e.g. `2026-08-12-bind-promotion-decision-merge/` shipped `mutation-proof.txt` + both suite logs). I independently confirmed bash 229/0, which is why this is not a blocker, but a claim of verification with nothing recorded is exactly what the evidence convention exists to prevent. Fix: drop the suite logs and mutation output into `state/evidence/2026-08-13-s3-reviewer-identity/` in a follow-up commit on this branch.
2. `plugin/engine/lib/risk.ps1:397-401` — **nit** — `[bool]$ReviewerConfigured` will coerce a non-empty string (e.g. `"0"`) to `$true` if a caller ever passes one positionally. The only caller is /promote prose which is told to compute a real boolean, and the sh twin's `!= "1"` check is strict, so this is theoretical; not worth churn now, just worth remembering if a scripted caller ever appears.

No blockers. The one recurring-class candidate is already ratcheted in this very batch (the sh arg-list-header rule in `plugin/engine/CLAUDE.md`), so no new `/ratchet` rule proposed beyond finding 1's evidence habit — if unrecorded verification claims recur, ratchet: "A fix_plan annotation that cites test counts or mutation runs must name the evidence file recording them, in the same commit."

VERDICT: SHIP
