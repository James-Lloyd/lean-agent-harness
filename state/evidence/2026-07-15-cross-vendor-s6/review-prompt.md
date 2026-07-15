You are a fresh-context, skeptical code reviewer. Judge ONLY the diff described below on its own merits
against the written spec — you have NOT seen the conversation that produced it. This is a DOCS-ONLY change
to two Claude Code slash-command markdown files (and their byte-identical plugin twins). Do not run any
write commands; you are in a read-only sandbox. You MAY read files in the repo to verify claims.

## The task (fix_plan item "Cross-vendor S6")
Rewrite `/harness-doctor` check 10 + add a `/harness-init` per-phase model interview.
Done when: check 10 (+plugin twin) validates the `{model,fallback}` schema across surfaces
— (a) value legality (each model/fallback is a known Claude alias/ID OR the literal `codex`),
(b) session must be Claude, (c) each agent frontmatter `model:` == its phase's PRIMARY when Claude,
ELSE (primary==codex) == the phase's Claude FALLBACK, (d) no `codex->codex` fallback is allowed,
(e) codex reachability probe stays ⚠️ (not ❌) and reports for EVERY codex-routed phase —
AND `/harness-init` (+twin) interactively picks model+fallback per phase with recommended defaults.

## The authoritative spec
`docs/execution-plans/2026-07-14-cross-vendor-per-phase-model-routing.md` — read §4a (default table),
§4e (doctor check 10, the five rules), §4f (harness-init interview). The diff must faithfully encode
§4e in check 10 and §4f in the init model-routing bullet.

## Ground-truth facts to check the docs against (verify by reading the files)
- Shipped config `harness/harness.config.json` → `models`:
  session={opus,null}, explore={haiku,null}, plan={fable,null}, implement={opus,codex},
  review={codex,fable}, evaluate={fable,null}, docs={haiku,null}, codex block present.
- `.claude/settings.json` model == opus (== session.model, Claude ✓).
- Agent frontmatters (`.claude/agents/*.md`): planner=fable, generator=opus, reviewer=fable,
  explorer=haiku, evaluator=fable, doc-gardener=haiku.
- The phase→agent map the doctor must assert: planner→plan, generator→implement, explorer→explore,
  reviewer→review, evaluator→evaluate, doc-gardener→docs.
- The interesting branch: review.primary==codex, so `reviewer` frontmatter must equal review's CLAUDE
  FALLBACK (fable), NOT codex. Check the diff's check 10 says this correctly, and that the harness-init
  table/prose says it too.

## The diff under review (staged)
See `state/evidence/2026-07-15-cross-vendor-s6/staged.diff` in the repo (read it). The two changed files are:
- `.claude/commands/harness-doctor.md` — check 10 rewrite.
- `.claude/commands/harness-init.md` — the "Model routing" bullet in Step 3.
(The plugin twins `plugin/commands/harness-doctor.md` and `plugin/commands/harness-init.md` are asserted
byte-identical by git index-blob hash — you need not re-verify that; focus on correctness of the prose.)

## What to judge
1. Correctness vs §4e: do all five rules (a–e) appear in check 10, stated accurately? In particular is
   rule (c) the "frontmatter == primary-when-Claude, else the phase's Claude fallback" rule correct, and
   does it correctly identify the `reviewer`→`fable` branch under the shipped config?
2. Correctness vs §4f: does the init bullet walk each phase picking model+fallback with the §4a
   recommended defaults, honoring "session must be Claude" and "no codex->codex"?
3. Legacy tolerance: does check 10 still accept the legacy flat `"phase":"alias"` form and legacy
   top-level `reviewFallback` as valid (not drift), per Decision 2 / the resolver's behavior?
4. Internal consistency: any claim in the new prose that contradicts the shipped config or the actual
   agent frontmatters? Any leftover reference to the OLD flat-only mapping (e.g. `models.reviewFallback`
   as the reviewer's phase, or "three surfaces" language that misdescribes the new checks)?
5. Any factual error, omission, or ambiguity that would make a future agent RUNNING /harness-doctor or
   /harness-init do the wrong thing.

## Output
A verdict line: `VERDICT: SHIP` | `VERDICT: FIX-THEN-SHIP` | `VERDICT: REJECT`, then a short numbered
list of findings (each: severity, file, the problem, the fix). If SHIP with no findings, say so plainly.
Be concrete and cite the exact prose. Do not nitpick style; judge correctness against the spec.
