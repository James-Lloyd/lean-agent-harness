<!--
  ROOT CONTEXT MAP — a navigation map, not a manual. Keep it under ~100 lines (shorter is better —
  the shipped map is ~60): every line competes with the task for attention. Point to docs/ and nested
  AGENTS.md files; never inline specs or style guides. Ratchet rules only from real failures (/ratchet)
  — delete rules that stop earning their place. /harness-init fills the {{PLACEHOLDERS}}.
  This file is read natively by Codex, Cursor, Copilot, Gemini CLI and friends; Claude Code reads it
  through the `@AGENTS.md` import in CLAUDE.md. Keep everything vendor-neutral here; anything that only
  Claude Code needs goes in CLAUDE.md's "Claude Code specifics" section.
-->

# {{PROJECT_NAME}}

{{ONE_LINE_DESCRIPTION}}

**Domain:** {{DOMAIN}} · **Type:** {{PROJECT_TYPE}} · **Shape:** {{PROJECT_SHAPE}}

## Components
Each has its own stack and gate, run in its own directory — see `harness/harness.config.json` → `components`.

| Component | Path | Stack | Run | Test |
|-----------|------|-------|-----|------|
| {{COMPONENT_NAME}} | `{{COMPONENT_PATH}}` | {{COMPONENT_STACK}} | `{{COMPONENT_RUN}}` | `{{COMPONENT_TEST}}` |

Cross-cutting e2e: {{ROOT_E2E}}

## The map
- `specs/` — **immutable** requirements; the contract.
- `docs/architecture/` + `docs/design-docs/` — how it fits together, and decisions already made (with the why).
- `docs/principles/workflow.md` — the task lifecycle (plan → execute → validate → review → record)
  that `/work`, `/plan`, `/verify`, `/review`, `/loop` drive.
- `state/` — live work: `fix_plan.md` (priority stack), `tasks.json` (manifest), `PROGRESS.md`,
  `handoff.md`, `evidence/`.
- `AGENT_NOTES.md` — operational gotchas. Append when you learn one.

## How to work
One task per iteration — the top unchecked item in `state/fix_plan.md`. A task is done when the
changed component's full gate **and** the root gate pass (commands in `harness/harness.config.json`)
and end-to-end evidence of the user-visible behavior exists under `state/evidence/` — unit-green
alone is not done. Commit when green (exception: in the headless loop the runner commits —
PROMPT.md wins there); roll back a red tree rather than patching over it. At task boundaries prefer
a written handoff and a fresh context over compaction — state lives in files.
Shell hygiene that keeps permission prompts down: run commands with **absolute paths instead of a
`cd … &&` prefix** (a `cd` inside a compound command defeats the read-only auto-allow and prompts),
and inspect files with the file-read/search tools rather than inline `node`/`python` heredocs (an
interpreter heredoc can never be allowlisted, so each one is a prompt or a classifier round-trip).

## Session isolation — one session = one worktree
Each interactive session runs in its **own git worktree**, so two concurrent sessions on this repo
never share a working tree or git index. Enter a worktree branched from origin's default **before
editing** (Claude Code: see CLAUDE.md; anything else: `git worktree add`). Land work by **PR to
`main`** (state edits included).
- **Task-claim convention.** The shared queue (`state/fix_plan.md`/`tasks.json`) forks per worktree, so
  two sessions branched from `main` see the *same* "next up". Point each session at a **distinct** task,
  and as your first commit stamp the task line with your branch — `- [ ] (wip: <branch>) <task>`. The
  branch stamp makes a double-grab **textually unique**, so the two PRs are guaranteed to conflict at
  merge; a bare identical `[x]` tick would 3-way-merge silently and both could land. Full discipline:
  `docs/principles/workflow.md`.

## Guardrails
- Never weaken or delete a test to go green. Fix the code or escalate.
- Never edit `specs/`. Propose changes to the human (`/plan`, `/onboard`, `/harness-init` may author
  *new* specs with approval).
- Escalate ambiguous product decisions instead of guessing.
- Review in a fresh context (`/review` / the `reviewer` subagent) — the doer is not the judge.
- Destructive commands are hook-blocked; don't route around the hooks.

## Project rules (the ratchet — grows only from real failures)
<!-- Add via /ratchet: "- [YYYY-MM-DD] <rule> — because <the failure it prevents>" -->
- [2026-07-14] A fresh-context judge subagent that dies on its model's usage cap gets re-spawned with
  a `model:` override; `review`/`evaluate` carry a Claude fallback in config for the headless path.
- [2026-07-26 · consolidated 2026-08-11] **A fact you change in one prompt surface exists in others —
  find them before you close.** Grep the whole repo for the literal (path, count, field name, phrase)
  you just edited. Four incidents, one lesson: a stale fact recurred in a sibling surface (07-26); an
  engine edit landed in `loop.ps1` but not the `.sh` twin (07-29); a deleted doc block left inbound
  pointers dangling, so rehome the content or fix the pointer *in the same change* — a pointer into
  deleted content is worse than the verbosity (07-29); and `/harness-migrate` deleted engine files from
  consumers without updating the plugin's own checks against those paths, so harness-doctor checks 1+7
  failed on every correctly-migrated repo (07-30).
- [2026-07-30] A committed config pointer ($schema, profile, path) is repo-relative or plugin-resolved,
  never an absolute local path — it dies on the next device (a consumer repo's $schema pointed at this
  machine's harness checkout).
- [2026-07-30] Compression may not swap a concrete fact for a pointer unless the pointed-at
  file/skill/command is verified to exist — resolve it before closing (a consumer map lost its model
  names to an unverified skill pointer).
- [2026-08-06] A doc that names a plugin-owned file as a WRITE target must say what a *consumer* repo
  writes instead — the installed cache is outside the project, shared machine-wide, and reverted by
  `/plugin update` (the routing skill told migrate to edit agent frontmatter that consumers can't own).
- [2026-08-06] A test pinning a doc table to a config asserts the value in its own COLUMN (split the
  row) and reads config keys via `PSObject.Properties[...]` — a row-wide match false-passes off a
  neighbouring cell, and a bare `$obj.$key` aborts the whole suite under StrictMode instead of failing.
- [2026-08-11] A bare model **alias** (`opus`, `sonnet`, `fable`) floats to the newest model in that tier
  — it is a moving pointer, not a pin. Write the full `claude-*` ID anywhere the *generation* matters and
  the alias only where the *tier* is the point (`haiku` for scouts). Found live: `settings.json` said
  `"model": "opus"` intending Opus 4.8 while the session was actually running Opus 5.
- [2026-08-11] A config key that nothing reads is worse than no key — it advertises a control that does
  not exist. Before adding one, name the code path that consumes it; when deleting the consumer, delete
  the key in the same change (`verification.freshContextReview` sat in the schema and every config for
  months while `/work` ran the review unconditionally — turning it off disabled nothing).
- [2026-08-12] A change to a shipped engine function's signature or behaviour bumps
  `plugin/.claude-plugin/plugin.json` `version` in the SAME diff — an unbumped version leaves a
  consumer's `/plugin update` serving a cached prose/engine pair from different builds (found in review
  of the promotion-decision signature change: the lib changed but the version stayed 0.2.9).
- [2026-08-12] A doc that offers "git will conflict visibly" as a safety backstop must make the competing
  edits TEXTUALLY UNIQUE — a 3-way merge auto-resolves byte-identical changes silently, so two sessions
  ticking the same `fix_plan.md` line `[ ]`→`[x]` both land with no signal. Stamp the claim with the
  branch so a double-grab diverges and actually conflicts (found reviewing the worktree-isolation change).
- [2026-09-04] A `fix_plan.md` line ticked `[x]` names its `state/evidence/<dir>` in the DONE comment, and
  the PROGRESS line cites both twins' gate counts — a tick with no evidence dir is not done. Found live: V1
  of the vendor refit was ticked on unit-green alone and the fresh-context reviewer rejected it.
- [2026-09-04] When a global config key gains a per-phase override, grep the key name in the skill, the
  doctor check AND the schema description before closing — the sentence "X reads the global key" lives in
  all three (V2 left it in the model-routing skill twice, doctor 10(e), and the schema's effort description).
- [2026-09-04] A doc claim that a guard hook allows or denies a payload shape must be backed by a probe
  carrying the DENYLISTED content, not a benign one — a benign probe never reaches the fallback branch.
  Found in review: `block-destructive` scans the whole payload when `tool_input.command` is absent, so
  the generated Codex hooks under matcher `*` would have denied any edit mentioning `rm -rf`.

- [2026-09-05] A generated config, hook, or agent file for a FOREIGN tool is verified by making that tool LOAD it
  and ACT on it (a one-line `codex exec`), never by asserting the emitted text; and a denial contract is verified by
  the destructive command NOT running, never by the hook's exit code. V3 shipped text-green and live-dead on four
  counts (two fatal config keys, project hooks never loaded headless, exit-2 denials ignored) — all found by V5.
  When a live-fire disproves a fact, sweep the generated artifacts' own runtime output and help text too, not
  just the docs — an operator reads the tool's stdout, not the design doc (the generator kept printing the
  disproved claim as its last line; caught in review).
- [2026-09-06] **A guardrail predicate is not verified until it has run over a REAL input at real size.**
  Unit fixtures are small by nature, and a whole class of shell defect only appears past a buffer
  boundary. `/promote`'s money rule — the one rule the design says must never fail open — passed twelve
  green assertions while reporting no money vocabulary whatsoever in a real 167 KiB diff, because
  `printf | grep -q` loses its match to SIGPIPE under `pipefail` above 64 KiB. Two sibling guards
  (`usage_limit_error`, fleet's protected-path check) carried the same shape. Before trusting any
  classifier, sniffer or tamper guard, run it over a real artifact of the size it will really see, and
  leave that oversized case in the suite.
- [2026-09-06] **A mutation check must make the pre-fix code return a WRONG ANSWER, not throw** — and
  the premise you are fixing under is a hypothesis until a probe on a real host confirms it. The
  strict-bool task sat in `fix_plan` for a month asserting that a `[bool]` param coerces `"0"` to
  `$true` and reaches AUTO; two fresh-context reviews had said so. Probing it showed the opposite —
  strings are *refused* by the binder, and it is nonzero NUMBERS that coerce. The fix was still
  needed, but the regression tests written from the stated premise pinned the wrong thing: against
  the pre-fix code a string argument raises a binding exception, so those assertions would have gone
  red on an ERROR rather than on a fail-open, proving nothing about the gate. Run the new assertion
  against the pre-fix code and check the failure is a wrong VALUE; if it is a stack trace, you have
  tested the type system, not the guard. Corollary: a semantics claim inherited from a review or a
  plan entry gets probed before it is written into a comment, or you ship a correct patch that
  teaches the next reader something false.
- [2026-09-06] **Closing a `fix_plan` item greps `AGENT_NOTES.md` and `state/` for the task's own WHY
  text** — the note that justified the task is the surface most likely left asserting the defect still
  exists. The here-string conversion corrected `plugin/engine/AGENTS.md` and design-doc 001 but left
  `AGENT_NOTES.md` saying, present tense, that the hooks still carry the fail-open, that they are safe
  only because they set no `pipefail`, and that the conversion was still queued — and pointing at the
  single-line fixture that same change had just proved was false comfort. Found by the fresh-context
  reviewer, not by the doc sweep that preceded it, because the sweep grepped for the *code* pattern
  and the stale note describes it in prose.
- [2026-09-06] **A buffer threshold is bisected per producer/consumer pair, never inherited from a
  sibling defect** — and a regression test for a branch the suite cannot reach by default is written
  with that environment forced. `money_signal`'s `printf | grep` turns over at 64 KiB; the visually
  identical `tr < file | grep -qx` in `codex-setup.sh` still returns `PIPESTATUS=(0 0)` at 114 KB and
  only fails at 289 KB, because an external producer plus grep's own read buffer absorbs far more. A
  114 KB fixture written from the inherited 64 KiB figure passed against the broken code. Separately,
  `protect-specs.sh`'s degraded no-jq branch — the highest-cost site of the four, since its failure
  admits an edit to `specs/` — was untestable in CI because the whole block is gated on
  `command -v jq` and jq is always installed. **Forcing it took two attempts, and the first repeated
  the defect:** `env -i PATH=/usr/bin:/bin` looks jq-free but on Linux jq IS in `/usr/bin`, so the
  proof skipped on the Linux job and ran only on Windows — visible in the CI log, invisible in the
  exit status. Point `PATH` at a temp dir of exec wrappers for only the commands the branch needs.
  And give a forced-environment test a POSITIVE CONTROL: "denied" and "crashed" are both non-zero, so
  without one, a hook dying on a missing command reads as a pass. "The suite is green" says nothing
  about a branch it never entered — and "the assertion passed" says nothing if it never ran.
- [2026-09-06] **A claim of SILENCE is earned only by a probe that captured the FULL output** — a
  filtered `grep` cannot prove absence, and a re-verification banner names *which* claims were
  re-measured instead of saying "everything still holds". Both halves came from one review of the
  Codex 0.153.4 pass: "an untrusted project skips its config silently, no warning" was asserted from a
  probe that piped the run through `grep -E '^(model|ERROR|error)'`, so a `warning:` line would never
  have been seen; and the doc banner claimed "every point below still holds" while the section beneath
  it recorded the one point that had *changed*, alongside several never re-run at all. Re-running
  unfiltered did vindicate the silence claim — that is luck, not method. Capture everything, then
  assert; and when re-verifying against a new version, state per claim which version it rests on.

- [2026-09-07] A fact about a foreign tool quoted in prose **names the results file and line that
  holds it**, and the re-runnable probe **contains the arm that produced it**. A claim whose only
  home is a script comment saying "measured in run 1" is unverified, however true it feels. Found
  twice: the `codex doctor` claim was overstated in the 0.153.4 re-verify, then restated in six
  surfaces by the agent-role probe on the strength of an uncommitted run — and when the arm was
  finally written, the claim turned out to be **false** (doctor does report it; the original had
  read only the first 30 lines). The citation requirement is what converts "a filtered view cannot
  prove silence" from a lesson people nod at into one the artifact enforces.

- [2026-09-07] A path/secret scrubber, and the guard behind it, are proven against **every escaping
  the tool actually emits** (`/`, `\`, `\\`), not just the one that happened to be in the transcript
  you looked at. Codex prints some paths JSON-escaped, and `Users\\<name>` matches neither a
  single-separator scrub rule nor the pre-commit denylist, whose character class consumes one
  separator and then expects the name. Both missed it and a real username reached a commit in a
  public repo. The proof fixture carries every form, and asserts on the **username itself** — an
  assertion that reuses the guard's own pattern inherits the guard's blind spot.
- [2026-09-07] A documented cost switch is honoured by **every** script the doc points at, or the doc
  names the ones it does not cover. "Set `PROBE_SKIP_MODEL=1` to run only the free parts" was false
  for seven of nine paid arms, so anyone re-running the probes cheaply would have paid for all of
  them. Prove it with a stub on `PATH` that fails loudly when the paid path is taken, plus a negative
  control that fires when the switch is off — otherwise the proof passes on a script that never calls
  the tool at all.

- [2026-09-08] **A new denylist pattern is probed against the REAL command vocabulary of the platform
  it will run on, before "the false positives are X" is written down.** Porting the `.ps1` guard's
  cmd.exe patterns to the `.sh` twin carried the switch matched ADJACENT to the command, which on
  POSIX denies `rmdir /srv/cache`, `rmdir /sys/...`, `rd /storage/...` — `/srv /sys /sbin /snap
  /share /storage` are ordinary roots, and the `.sh` hook is the one that actually runs there. The
  same shape also MISSED `rmdir /q /s x` and `del /f /s x`, real recursive deletes with the flags in
  the other order: one pattern, wrong in both directions, and the shipped `.ps1` had carried both
  defects for months because only one of its four patterns was ever asserted. Two corollaries. (a)
  The twin whose BEHAVIOUR is correct is not therefore the twin whose TESTS are good — when closing a
  parity gap, count the assertions on both sides, not just the patterns. (b) A false-positive list
  assembled from prose examples will always undercount; the author's list named one FP (prose quoting
  a switch) and a differential probe over real commands found three more that mattered far more.
  **(c) And the fix for an over-block is itself a loosening, so it gets DIFFERENTIALLY DIFFED against
  the pattern it replaces, over every form the OLD one caught.** The obvious repair here — require a
  space-or-end boundary after the switch, so a path cannot impersonate it — shipped a real BYPASS and
  was caught only by a second review: cmd.exe accepts CONCATENATED switches, so `rd /s/q x` and
  `del /s/q x` end the switch with `/`, and a trailing switch can be followed straight by `&&`. All
  of those were denied by the crude original and allowed by the careful replacement, including
  `cmd /c rd /s/q <dir>` — the exact phrasing an agent uses from the Bash tool on Windows, live-fired
  and confirmed to delete a populated tree. A branch whose purpose was to CLOSE a guard gap was one
  review away from shipping a net loss of coverage. **(d) The rule that finally worked is written
  against the foreign shell's switch GRAMMAR, not against a boundary character.** Widening the
  boundary to a class was the third wrong answer, and a third review live-fired past it too: a run
  led by another flag (`del /f/s/q x`, the canonical Windows build-script idiom) and the no-space
  form (`rd/s/q x`) both deleted real files, and the class had meanwhile created a fresh
  false-positive family (any text with the word `del` beside a path segment ending in s or q).
  Enumerate the token forms the parser actually accepts — a switch is a run of one-letter `/x`
  segments, positioned anywhere, optionally with no separating space — and live-fire each; boundary
  characters and flag order fall out of that as consequences rather than being the rule. Live-fire
  the negatives too: `/sq`, `/qs` and `/s/build` are all REFUSED by cmd.exe, so matching them would
  buy nothing and cost over-blocking. Pin the negative controls as well as the denials.
  **(e) Express a token boundary as "NOT A CONTINUATION", never as a list of terminators — a list is
  always short by something.** Even written against the grammar, the run-END was first spelled
  `([[:space:];&"]|$)`, and cmd.exe also ends a switch run at `>`, `)` and `,`: `rd x /s/q>nul` and
  `if exist x (rd x /s/q)`, two of the most idiomatic batch spellings there are, walked straight
  through and deleted their targets. The predecessor had caught them only BY ACCIDENT (its class
  contained `/`, so it matched at a multi-segment run's inner separator and never reached the end),
  so removing `/` on sound grammatical grounds silently removed the accident too — which is exactly
  why clause (c)'s differential is not optional. `([^a-zA-Z/]|$)` has no list to be short by.
  **(f) The differential is a DELIVERABLE, not a habit**: ship the machine-checked set "denied by the
  predecessor, allowed by this one" as a committed evidence arm. Four rounds running, the round that
  skipped it is the round that regressed — including the round whose own diff added clause (c).
  **(g) That arm's own dismissal filter is an EXACT WHOLE-LINE allowlist of measured cases, never a
  substring regex, and each positive control is asserted PRESENT in the corpus it filters and DENIED
  by the current rule — not merely that it survives the filter.** A substring dismissal (`/logs/`,
  `/srv/`) silently grows its reach as the corpus grows, so the filter built to catch the next
  regression becomes the thing that hides it. And a control that only proves the filter can speak
  proves nothing about whether the corpus can accuse: measured on the first version of this arm,
  gutting the corpus from 1,342 forms to 334 left every control green and the arm still exiting 0.
  Adding the presence assertion immediately caught a control string the corpus had never generated.

- [2026-09-09 · codex] **A flag that PARSES is not a flag that BINDS.** The harness passed
  `--ask-for-approval never` to `codex exec` for months and the unit tests were green the whole time,
  because they asserted the string was **present in argv** — which it was. On codex-cli 0.153.4 the
  flag is rejected by `exec` outright and, in the only slot that accepts it, parses without taking
  effect: every transcript header read `approval: on-request`, and under that a READ-ONLY judge's
  `apply_patch` mutated the tree it was judging. Assert a foreign tool's **own report of its
  effective state** (its startup header, `--json` event, echoed config), never the argv you handed
  it; and prefer the spelling the tool confirms (`-c approval_policy="never"` flipped the header and
  the same write was refused). Corollaries: **(a)** the version matters — the identical flag DID bind
  on 0.144.3 (`state/evidence/2026-07-14-cross-vendor-s3/live-codex-readonly.log`), so this is a
  regression and the claim names its version; **(b)** the belt you thought was ornamental may be the
  only thing holding — the caller's post-review `git reset --hard` is what protected judged trees
  while the sandbox claim was false, so do not remove a redundant guard because the primary one is
  "guaranteed"; **(c)** a fix to a permission/sandbox argument gets the OPPOSITE case measured too
  (writers still write), or the fix is just a different outage.
- [2026-09-09 · codex] **A fix proven with a hand-assembled argv is not proven.** The first proof of
  the fix above ran a vector typed into a probe, not the one `codex_args` emits — different in three
  elements. Re-run the arm that drives the SHIPPED builder, ship it as a pre/post DIFFERENTIAL with
  the pre half read from the **git blob** (never transcribed), and make the arm refuse to run unless
  the two vectors differ by exactly the change under test. Caught by fresh-context review, which also
  made the point that the argv is the artifact the foreign tool consumes — the same reasoning as the
  2026-09-05 "make the tool LOAD it and ACT on it" rule, one layer down.
- [2026-09-09 · probes] **A probe that writes into `state/evidence/` honours an output-dir override,
  because the cost-switch proof will run every probe.** The first `skip-proof.sh` ran the probes in
  place with a stub on PATH: its stub runs overwrote **six real result files**, so the arm written to
  protect the evidence destroyed it. Probes now take `$PROBE_OUT_DIR`. And **a PATH stub must exist
  in every form the launchers resolve** — an extensionless `codex` is invisible to Windows
  PowerShell, so the PS probe skipped the stub, reached the REAL CLI during the negative control, and
  reported a clean "0 paid calls" for the arm that was supposed to prove the switch works.
- [2026-09-09] **A probe that reports a verdict must be able to report the OTHER one, and be shown
  doing it in the same run.** Five defects in one change, all in the *checking* code rather than the
  code under test, all invisible to a green run. (a) A PowerShell arm read `if (-not $ok)` on the
  RESULT OBJECT returned by `Invoke-ProjectGate` — a non-null object is always truthy, so the arm
  exited 0 whatever the gate said. Test the named property (`$ok.Passed`), and give every arm a
  negative control (a config whose gate step exits 1) so "green" is a measurement and not a
  formality. (b) An assertion that a path exists used `Test-Path (Join-Path $root $x)`, and on the
  empty `$x` — the exact pre-fix shape it was written to catch — `Join-Path` yields the repo root,
  which exists: it PASSED on the mutant. `-PathType Leaf` plus a non-empty guard. (c) An assertion
  guarding a code invariant grepped the whole file for two tokens; the mutant that re-opens the
  invariant still contains both tokens, so it could never accuse. Assert the POSITION (the single
  `which(` call must come after the guard line, inside that function's own body), and feed the arm
  the mutant to prove it goes red. (d) The extracted-block harness in that same arm did not reproduce
  the real suite's PREAMBLE (the engine dot-source that defines `Get-Prop`), so three assertions died
  on a missing command and were counted as "not failed": pass=3, fail=0, reported GREEN. An
  extracted-block runner copies the preamble, or it measures nothing. (e) `env ProgramFiles=… node …`
  from Git Bash does NOT set that variable — MSYS special-cases it and the child sees the real
  `C:\Program Files` (measured; `ProgramFiles(x86)` and `LOCALAPPDATA` did get through). Force an
  environment from the language that will spawn the child, and assert the branch you forced was
  actually entered.
- [2026-09-09] **A duration, cost or count written into prose names the arm and output file that
  measured it.** "~9 minutes, ~4.5 min each" was written into two surfaces from an impression; the
  measurements in the same evidence dir said 273 s and 333 s for the whole both-twin run. A figure
  with no citation is a guess wearing a number's clothes.
- [2026-09-09] **Evidence is scrubbed of the OS username by the PROBE'S OWN redirect, never at commit
  time.** The 2026-09-07 ratchet made the scrubber cover every separator form; this one moves it
  earlier. Seven `C:\Users\<name>` lines reached `state/evidence/` because the probes wrote raw and
  the author was to scrub later — the local pre-commit guard would have blocked the commit, which is
  the good case; the bad case is `--no-verify`. Each probe now writes its own output file and pipes
  it through `scrub.mjs` before returning.
- [2026-09-09] **A gate step is ONE string handed to a DIFFERENT shell per platform** (`cmd /c` on
  Windows via `Invoke-GateStep`, `bash -lc` on POSIX via `_gate_step`), so a cross-platform gate
  command cannot be a shell script path: cmd.exe refuses a forward-slash command path, and — measured
  — a bare `bash` under `cmd /c` resolves to **WSL's** `System32\bash.exe`, not Git Bash, which is
  only on PATH inside a Git Bash session. On a box without WSL that is a hard red; with WSL it would
  have run the suite in another OS entirely. Dispatch from `node` (already a harness dependency for
  exactly this reason in `plugin/hooks/run.mjs`) and locate a Windows interpreter BY PATH ON DISK.
- [2026-09-09] **A banner is not a signal if the caller never sees it.** Both engines print a gate
  command's output only when it exits non-zero, so anything a green command says — including a loud
  "half the engine went ungraded" — is captured and discarded under `loop`/`fleet`. A degraded-but-
  green mode needs an exit-code path (`HARNESS_GATE_STRICT=1`), and the doc says WHERE the banner is
  visible (`/verify`) rather than claiming it always is.

- [2026-09-09] **Correcting a routing/enablement predicate means grepping every CHECK that gates on the
  same predicate, not only the prose that describes it — a skip condition is a surface too.** Routing
  `review.second` to codex corrected four surfaces that said a phase's `codex{}` block is read only when
  `model` or `fallback` is codex; the fresh-context reviewer found a fifth, one section below two of the
  edits, in the same file: `/harness-doctor` check 12 skips with "no phase routes to codex" when no
  `models.*.model`/`fallback` is codex **and** `.codex/` is absent. A second-reviewer-only config
  satisfies both — so the check that exists to catch ungenerated Codex hooks silently disabled itself on
  exactly the config that needed it, while `fix_plan` and `PROGRESS` both cited that check as the
  mechanism that would catch it. A predicate copied into a skip/guard clause rots the same way a
  sentence does, and it rots invisibly, because a self-disabled check reports ℹ️ rather than ❌.
  Corollary from the same review: **state records overclaim controls that the evidence README states
  correctly** — "every arm carries a control" was written where only two of four did. Copy the README's
  wording into the state files, not a generous summary of it.

## Nested context
Subsystems carry their own `AGENTS.md` next to their code (in this repo: `plugin/engine/` holds the
engine's PS-5.1/twin-parity rules). When working in a subsystem, its local map applies too.
