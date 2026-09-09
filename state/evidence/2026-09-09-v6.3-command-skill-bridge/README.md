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
