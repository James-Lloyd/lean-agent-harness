# 2026-09-09 — V6.3: the command→skill bridge, and a shipped claim that was never true

**Verdict: GREEN**, with one correction to a fact the harness has shipped since slice V3.

Two claims, both live-fired on **codex-cli 0.153.4** (ChatGPT auth):

1. **The bridge works.** Every harness command is generated into
   `<project>/.agents/skills/harness-<command>/SKILL.md`, and `codex exec` **loads one and acts on
   it** — not merely receives it.
2. **`[[skills.config]] path` delivers no skills to `codex exec`.** The stanza the generator has
   emitted since V3 validates (omitting `enabled` is still fatal) but is inert. The plugin's six
   reference skills have never reached Codex that way.

## Files

| File | What it shows |
|---|---|
| `bridge-live-fire.txt` | The bridge: codex answers from the generated `harness-review` skill; control returns `NO-SKILL` |
| `bridge-transcript.log` / `bridge-control-transcript.log` | Those two runs |
| `skills-config-key.txt` | The same SKILL.md found under `.agents/skills/` and NOT via `[[skills.config]]` |
| `skill-location.txt` | `.agents/skills/` is discovered automatically — named or unnamed |
| `skill-discovery.txt` | The first, WRONG attempt (see below) — kept deliberately |
| `trust-inheritance.txt` | Trust is prefix-inherited: a trusted repo covers its own git worktrees |
| `probes/*.sh` | Re-runnable. `PROBE_SKIP_MODEL=1` skips every paid arm; `PROBE_OUT_DIR` redirects output |

## The measurement that matters

`bridge-live-fire.sh` asks codex a question answerable only from the generated skill body — the
harness's verdict vocabulary and its rule about who may review a change. Neither appears in the
prompt. With the bridge in place:

```
(1) ship / fix-then-ship / reject   (2) The doer must not be the judge.
```

With `.agents/skills/` moved aside, the same question returns `NO-SKILL`. The three-valued verdict is
the discriminator: a model reciting a generic ship/reject vocabulary from prior knowledge would not
produce `FIX-THEN-SHIP`, which is this harness's own.

## Two wrong turns, kept in the record

**1. "Skills do not load" — wrong, and the probe measured the wrong thing.** The first discovery run
put its canaries in a temp project. An *untrusted* project skips its whole `config.toml`, so the
skills roots were never read: the arm measured trust, not skills. `skill-discovery.txt` is kept as the
artifact of that error.

**2. The trust probe that "proved" trust is not inherited — a TOML bug in my own fixture.** It
appended `model_reasoning_effort = "low"` to the end of the generated `config.toml`, whose last
section is `[[skills.config]]`. In TOML a bare key belongs to the table above it, so the key landed
*inside* that table and did nothing — which the arm read as "the project config is not applied". With
the key prepended (above every table header) the same run reports `reasoning effort: low`: **trust IS
prefix-inherited.** The probe now asserts its own fixture is well-formed before believing its result.

Both errors have the same shape: the *checking* code was wrong while the code under test was fine.
That is this repo's most expensive recurring defect class, and the reason arm ordering here is
trust → location → config-key → bridge, each arm establishing the premise the next one needs.

A third, smaller one: the bridge arm first went red on a **correct** answer, because it grepped
case-sensitively for `SHIP` while codex had replied `ship / fix-then-ship / reject`.

## Corrections from the fresh-context review

The review returned FIX-THEN-SHIP with three blockers. Two changed shipped behaviour, one changed
this dir:

- **The `.agents/` gitignore append corrupted a `.gitignore` with no trailing newline** into the
  single line `.codex/.agents/`, destroying both patterns and un-ignoring a directory of
  machine-local absolute paths. Fixed in both twins; the regression fixture is mutation-checked (on
  the pre-fix append the whole-line `.codex/` count is 0).
- **One `...` character in an emitted PowerShell string.** `codex-setup.ps1` is BOM-less, so PS 5.1
  would have decoded it as Windows-1252 and shipped mojibake into all 14 generated skills, diverging
  from the bash twin's bytes. Both preambles are ASCII-only now.
- **`--check` said `fresh` with the whole bridge deleted** - and `/harness-doctor` 12 runs exactly
  that. Now gated on the skill count. The first fix of it exited 1 while printing *nothing*, because
  `find` on a missing dir aborts the script under `pipefail`.

Probe-side corrections, all in this dir:

- **All five probes truncated their log BEFORE the cost-switch guard**, so the advertised cheap
  re-run (`PROBE_SKIP_MODEL=1`) zeroed five committed result files. Guard now precedes the redirect;
  verified by running the cheap path across all five and confirming every byte survived.
- **Two probes could not be re-run at all** - their canary fixtures were never committed and never
  created. Each now writes its own and removes it.
- **The "inert" arm now carries an in-run witness.** It concluded from a NULL result while its
  premise (this project's config is honoured) came from a *different* run. A top-level
  `model_reasoning_effort = "low"` in the same file now proves, from that run's own header, that the
  config was loaded. Re-measured: the conclusion held.

## Controls

- **Bridge:** the generated skills are physically moved aside and the same question re-asked. It
  returns `NO-SKILL`, so the answer came from the bridge and not from codex reading the repo.
- **Config-key:** the *same fixture skill* is proven reachable under `.agents/skills/` in the same
  run. Without that, "not found via `[[skills.config]]`" could just mean the SKILL.md was malformed.
- **Location:** asked both named and unnamed, so "reachable" and "discovered unprompted" are
  distinguished rather than conflated.
- **Trust:** the fixture's well-formedness is asserted before the measurement is believed.
- Every probe greps its own scrubbed output for the OS username and fails if it survives.

## What this does NOT show

- **Anything about interactive Codex.** Every measurement is `codex exec`. That is exactly why the
  `[[skills.config]]` stanza is *kept* rather than deleted — it may serve an interactive session, and
  nothing here says otherwise.
- **That a Codex operator can complete a real harness task end to end.** The bridge is proven to
  deliver the instructions; running `harness-work` through a full task on a real repo is not done here.
- **Guardrail parity.** Unchanged and still the weak point: project `.codex/hooks.json` is not loaded
  under headless `exec`, so a Codex operator's guardrails are `--sandbox` + `approval_policy=never` +
  the gate until the user-level hooks are installed and trusted (still open in `fix_plan`).
- **Cost or latency.** Not measured; nothing here licenses a figure.

## Addendum — the Codex per-phase table, and a default that OSCILLATES

`probes/effort-model-coupling.sh` and `probes/pinned-model-binds.sh` were added while giving the Codex
side its own per-phase models and efforts.

**The default is not migrating one way — it flips.** Observed on this box, same account, same flags:

| time (local) | CLI default reported |
|---|---|
| up to ~16:11 | `gpt-5.6-sol` |
| ~18:10 – ~19:58 | `gpt-6-astra` |
| ~20:5x (pinned-model-binds arm 1) | `gpt-5.6-sol` again |

`effort-model-coupling.sh` rules out the obvious confound: passing `-c model_reasoning_effort` does
**not** select the model (bare / high / low all returned the same ID in one run). So an unpinned phase
can land on a different model between two runs an hour apart, in either direction. That is the whole
case for pinning a judge, and it is stronger than the original one-way observation.

**The pin binds, demonstrated twice against a differing default** — `gpt-5.6-sol` while the default was
`gpt-6-astra`, and `gpt-6-astra` while the default was `gpt-5.6-sol`. Both runs drove the shipped
resolvers and the shipped arg builder, never a hand-assembled argv, and the arm states that it could
not have demonstrated binding had the pin equalled the default.

**The Codex session model is a real surface.** `models.session.model` must be Claude — the Claude Code
window cannot swap vendor mid-session — but a Codex session is a different process, and
`models.session.codex{}` is now written as **top-level** `model` / `model_reasoning_effort` in
`.codex/config.toml`. Top-level is load-bearing: in TOML a bare key belongs to the table above it, so
emitting these after `[features]` would silently turn them into feature flags. Both suites assert the
keys precede the first table header. The mechanism is the one `trust-inheritance.sh` already measured
— a top-level key in that file changes the transcript header.

## Model-ID validity, and why the session header is NOT proof of it

`probes/model-id-check.sh <id>` answers "is this pin usable on this account", and writing it found a
hole in `pinned-model-binds.sh`.

**Codex echoes the REQUESTED model id in the session header before validating it.** Measured:

| id | header says | exit | outcome |
|---|---|---|---|
| `gpt-5.6-sol` | `gpt-5.6-sol` | 0 | usable |
| `gpt-6-astra` | `gpt-6-astra` | 0 | usable |
| `gpt-6-luna` | `gpt-6-luna` | 1 | **HTTP 400** — not supported on a ChatGPT account |
| `gpt-9-notarealmodel` | `gpt-9-notarealmodel` | 1 | **HTTP 400** — identical message |

So a header match alone passes on a model that cannot run. `pinned-model-binds.sh` captured the exit
code and only *printed* it; it now asserts it. That is the same defect class as the rest of this dir —
the checking code, not the code under test — and it is the third time in this slice.

**The error message is generic.** A deliberately nonsense id produces byte-identical text to
`gpt-6-luna`, so this box cannot distinguish "real model, wrong plan" from "no such model". Anything
stronger about `luna` needs a source other than this account.

**A bad pin fails loudly at the FIRST call, not silently** — no substitution was observed in any arm.
That is what makes pinning safe here: a retired id breaks the run, it does not quietly change judges.

## Effort support is PER-MODEL — and the config shipped an impossible pair for an hour

Asked to move `explore`/`docs` to `gpt-5.6-luna`, `probes/model-id-check.sh <id> <effort>` grew an
effort argument, and the first run of the shipped combination failed:

```
'minimal' is not supported with the 'gpt-5.6-luna' model.
Supported values are: 'none', 'low', 'medium', 'high', 'xhigh', and 'max'.
```

`gpt-5.6-sol` refuses `minimal` too. So the config committed in `163a04e` — `explore: gpt-5.6-sol @
minimal` — **could never have run**: every Codex explorer would have died with HTTP 400 on its first
call. It was caught only because James asked for a different model.

| pair | result |
|---|---|
| `gpt-5.6-luna` @ default | runs |
| `gpt-5.6-luna` @ `none` | runs |
| `gpt-5.6-luna` @ `low` | runs |
| `gpt-5.6-luna` @ `minimal` | **400 unsupported_value** |
| `gpt-5.6-sol` @ `minimal` | **400 unsupported_value** |
| `gpt-6-luna`, `gpt-9-notarealmodel` | **400**, generic "not supported ... with a ChatGPT account" |

Two repo-wide claims are disproved by that error text. **`minimal` is not "the codex level"** — it is
refused by both pinned models — and **`max` is not "Claude-only"**, since the API lists it among the
supported values. The schema enum was missing `none` entirely. Schema, routing skill and doctor 10(e)
all corrected; the suites' `explore` assertion had been pinning `minimal`, i.e. pinning a combination
that could not run, and now pins `none`.

**The lesson is narrow and expensive: verify the PAIR, not the parts.** A model id that resolves and
an effort level that is in the enum can still be a runtime 400 together. `model-id-check.sh <id>
<effort>` is the arm; it asserts a zero exit *and* that the header echoes back the effort asked for.
