# Evidence — per-phase model routing retune + declared reasoning effort (2026-08-06)

**Change (user-directed):** orchestrator = opus@medium, planner = fable@high, implementer = codex@high,
reviewer = fable@high with an opus@medium fallback. Reasoning effort becomes a *declared* field
(`effort`/`fallbackEffort`) in `harness.config.json` + the schema, enforced by `.claude/settings.json`
`effortLevel` (session) and agent `effort:` frontmatter (subagents). Plugin 0.2.5 → 0.2.6.

Scope decision by the human: config + frontmatter only. Plumbing `--effort` through the headless
dispatcher stays the open follow-up (`state/fix_plan.md`).

## Artifacts

| File | What it shows |
|------|---------------|
| `run-tests-ps.txt` | PowerShell self-tests — **143 passed, 0 failed** |
| `run-tests-bash.txt` | bash self-tests — **134 passed, 0 failed** |
| `schema-validate.txt` | `harness.config.json` validated against `harness.schema.json` (Draft-7) — **0 errors**; `additionalProperties:false` on `phaseRouting` still admits every key the config writes |
| `resolved-routing.txt` | The engine's own resolvers (`phase_model`/`phase_fallback`, gate.sh) run against the real config — proves the new keys don't disturb resolution |
| `doctor-check10.txt` | The user-visible check the change exists for: doctor 10(c)+(e) agreement across all three surfaces — config ↔ settings.json ↔ agent frontmatter, all **OK** |

## End-to-end behaviour observed live, not simulated

The reviewer subagent was spawned on the `review` primary (**fable**) and **died on a real Fable 5
usage cap** mid-review — then re-ran to completion on the phase's declared `fallback` (**opus**). That
is the `review = {fable, opus}` routing and the CLAUDE.md [2026-07-14] cap ratchet firing on live
traffic, which is exactly the path this change tunes.

## Review

Fresh-context reviewer (opus fallback arm): **ship, zero blockers**, 8 doc-surface should-fixes — all
applied before commit (duplicate `(e)` sub-bullet in doctor check 10 → relabelled `(f)`; stale parent
descriptions in schema + doctor preamble; missing `fallbackEffort` inheritance rule; overstated
enforcement in the config `_comment`; stale README routing line).

One reviewer nit was **escalated and disproved**: it flagged the claim "session effort has no settings
key" as unverifiable from this repo. Checked against the Claude Code docs — `effortLevel` **is** a real
settings.json key (`low|medium|high|xhigh`), overridable by `CLAUDE_CODE_EFFORT_LEVEL` and
`claude --effort`. Session effort is therefore file-enforced, and doctor 10(e) checks it rather than
carving it out.
