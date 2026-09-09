# 2026-09-09 — live-fire the codex invoke path (codex-cli 0.153.4)

**Task:** `state/fix_plan.md` — *"Live-fire the codex invoke path once codex CLI is installed (flag
placement, `exec -` stdin, `--output-last-message` parse) — done when: one real codex review run log
parses to a verdict; adjust flags per installed version."* Its 2026-07-14 note left two things open:
a real **workspace-write** run, and a **full periodic-review verdict parse from the loop**. Both are
closed here, on the installed 0.153.4 rather than the 0.144.3 the partial was measured on.

## The finding: a read-only codex judge could write to the tree

The harness's judge phases (review, evaluate) rest on one safety property — *a judge must never
mutate what it judges* — and the engine's own header claimed the sandbox enforced it. On 0.153.4 it
did not: a `read-only` run's `apply_patch` created a file.

Root cause, from the CLI's own transcript headers:

- `--sandbox` **does** propagate from the global slot (`sandbox: read-only` vs `sandbox:
  workspace-write [workdir, /tmp, $TMPDIR]`). That flag was never the problem.
- `--ask-for-approval never` **does not bind on this version.** `codex exec` rejects the flag
  outright (`error: unexpected argument '--ask-for-approval' found`, exit 2 — measured, free), so the
  global slot is the only one that parses; and from there the effective policy stayed
  `approval: on-request` in every 0.153.4 transcript. With `on-request` and no human to ask, the
  patch went through.
- **It is a regression, not a permanent property.** On **0.144.3** the same global flag bound:
  `state/evidence/2026-07-14-cross-vendor-s3/live-codex-readonly.log` header reads `approval: never`.
  That is why the flag is kept alongside the new override rather than replaced by it.

The fix is one argument — `-c approval_policy="never"`, emitted after `exec`, where `-c` is accepted.
Arm H is the differential that proves it **through the shipped builder**:

| case (same builder, same prompt) | header | wrote? |
|---|---|---|
| PRE (`codex_args` at HEAD) · read-only | `sandbox: read-only` \| `approval: on-request` | **yes** — the defect |
| POST (working tree) · read-only | `sandbox: read-only` \| `approval: never` | **no** — `patch rejected: writing is blocked by read-only sandbox; rejected by user approval settings` |
| POST · workspace-write | `sandbox: workspace-write` \| `approval: never` | **yes** — writers unaffected |

The third row is what makes the fix shippable rather than merely safe: an approval policy that also
disabled `implement`/`plan`/`docs` on codex would have been a worse bug than the one being fixed.

**Two things worth carrying forward.** The caller's post-review `git reset --hard` is not ornamental
— it is what protected judged trees for the whole period this was broken (arm G confirms the tree is
clean after a real codex judge runs). And the harness's *unit* tests were green throughout: they
asserted the flag was **present in argv**, which it was. Only running the binary showed that the CLI
parsed it and ignored it.

## Arms

| # | proves | cost | script |
|---|---|---|---|
| A | every flag the harness emits exists on this version, in the slot it is emitted in | free | `probes/live-fire.sh` |
| B | `invoke_codex` read-only: prompt over `exec -` stdin, `--output-last-message` round-trips the final text | 1 call | `probes/live-fire.sh` |
| C | `invoke_phase` → codex → `review_verdict`, the dispatcher hop the loop's review point takes | 1 call | `probes/live-fire.sh` |
| D | the fail-closed verdict parse (last `VERDICT:` line wins; none ⇒ `NONE`) | free | `probes/live-fire.sh` |
| E | the external watchdog: a 1 s bound ⇒ exit **124** and the kill is logged | ~1 s | `probes/live-fire.sh` |
| F | `codex_available`: real CLI yes, missing CLI no, api-key auth requires `CODEX_API_KEY` | free | `probes/live-fire.sh` |
| G | **the loop's review point end to end** — real `harness/loop.sh --mode auto`, implementer stubbed, judge routed to codex | 1 call | `probes/loop-review-codex.sh` |
| H | **the differential**: PRE vs POST builder, read-only + workspace-write | 3 calls | `probes/builder-differential.sh` |
| I | the diagnosis: sandbox/approval matrix with a no-flag control | 3 calls | `probes/approval-matrix.sh` |
| K | the **PowerShell twin's** argv against the real CLI, with a writer control | 2 calls | `probes/ps-twin.ps1` |
| — | `PROBE_SKIP_MODEL=1` really suppresses every paid call, with a negative control | free | `probes/skip-proof.sh` |

Arm H's design is the fresh-context reviewer's, and it corrected a real weakness: the fix's first
proof used a **hand-assembled** argv, which is not the artifact the CLI consumes in production. Both
halves now come from `codex_args` itself — the PRE half read from the **git blob at HEAD** rather
than transcribed — and the arm refuses to run unless the two vectors differ by exactly the approval
override, so it cannot quietly agree with itself.

Arm K exists because every other arm is bash while **PS 5.1 is this engine's primary Windows
runtime**, and it does not escape embedded quotes for native commands — `approval_policy="never"`
could plausibly have arrived as `approval_policy=never`. Measured: it binds (header `approval:
never`), read-only refuses, workspace-write writes.

## Results

```
arm A  8/8 ok   — global accepts --sandbox/--ask-for-approval/--cd; exec accepts
                  --skip-git-repo-check/--output-last-message/--sandbox/--cd; exec REJECTS
                  --ask-for-approval, so the before/after split in codex_args is required
arm B  exit 0   — final message <<LIVE-FIRE-TOKEN-8842>>
arm C  exit 0   — path='codex', used_fallback=0, verdict='SHIP'
arm D  ok       — a quoted "VERDICT: SHIP" preamble loses to the last line (REJECT); no line ⇒ NONE
arm E  exit 124 — watchdog killed it; log carries "watchdog kill, failing closed"
arm F  ok       — real CLI available; missing CLI refused; api-key needs CODEX_API_KEY
arm G  ledger   — {"iter":1,"result":"review","path":"codex","model":"codex","verdict":"SHIP"},
                  reviewer transcript on disk, tree CLEAN after the judge
arm H  GREEN    — PRE wrote / POST refused / POST workspace-write wrote (table above)
arm I  recorded — I1 on-request ⇒ wrote; I2 (+override) never ⇒ refused; I3 (no --sandbox) ⇒ wrote
arm K  GREEN    — PS twin: read-only `approval: never` and no file; workspace-write wrote
skip   GREEN    — 0 paid calls from any probe with the switch on; 3/2/1 attempted with it off
```

Arm G's transcript is worth reading (`arm-g-review-transcript.log`): codex actually inspected the
fixture — it ran `git diff --check`, noticed `specs/` and `docs/principles/` were absent from both
trees, and returned `VERDICT: SHIP`. A real review, not a shape that merely parses.

## What shipped

- `plugin/engine/lib/invoke-codex.{sh,ps1}` — both arg builders emit `-c approval_policy="never"`
  after `exec`; both headers state the measured behaviour, name the version each claim rests on, and
  cite the 0.144.3 log that justifies keeping the global flag.
- `harness/tests/run-tests.{sh,ps1}` — 4 mirrored assertions per sandbox mode: the override is
  present, sits **after** `exec`, is the **argument of a `-c`**, and the flag stays **before** `exec`.
  Position is the whole finding, so a presence-only assertion would have passed against the broken
  build — which is exactly what the old ones did.
- `AGENT_NOTES.md`, `docs/codex-setup.md`, `plugin/commands/review.md`,
  `docs/design-docs/002-vendor-agnostic-routing.md`, and two stale `state/fix_plan.md` notes that
  still said the write path was untested.
- `plugin/.claude-plugin/plugin.json` → **0.4.1** (shipped engine behaviour changed).

## Residuals (stated, not hidden)

- **Escalation behaviour for WRITER phases changed too, and only one half is measured.** Under
  `on-request` with no human, escalations were auto-granted; under `never` they are refused. Arm H's
  third case proves an in-workspace write still succeeds. It says nothing about an implement phase
  whose command needs an escalation (network, a path outside the workspace) — that previously
  proceeded silently and now hard-fails. Failing closed is the right direction, but it is a
  behaviour change to `implement`/`plan`/`docs`, not only to the judges.
- **Measured on Windows only.** Codex's OS-level sandboxing differs by platform (Seatbelt on macOS,
  Landlock on Linux); whether a read-only run there would also have let `apply_patch` through is
  unmeasured. The fix is platform-independent — it changes the approval policy, not the sandbox —
  but the severity of the bug it fixes may not be.
- **Generated Codex judge agents are a separate surface.** `.codex/agents/{reviewer,evaluator,…}.toml`
  carry `sandbox_mode = "read-only"` and no approval key, so a judge spawned through that path
  inherits the session's policy. Whether an agent table accepts an approval key is unmeasured;
  `docs/codex-setup.md` now says so rather than implying the sandbox is the guarantee.
- **One model, short prompts.** Nothing here says anything about review quality — only about plumbing.
- Arm G stubs the implementer, so a codex WRITE inside a full loop iteration is still unproven; that
  is Overnight Stage 1b's job.

## Process note (kept deliberately)

The first version of `skip-proof.sh` ran the probes **in place**, so its stub runs overwrote six real
result files — the cost-switch proof destroyed the evidence it was written to protect. Every arm was
re-run afterwards, and the probes now take `$PROBE_OUT_DIR` so a stub run cannot write into
`state/evidence/`. Its first negative control also passed for the wrong reason: the bash-only stub was
invisible to PowerShell (which will not execute an extensionless file), so the PS probe reached the
**real** CLI during the control. The stub now ships as `codex` and `codex.cmd`.
