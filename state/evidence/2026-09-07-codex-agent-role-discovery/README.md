# Codex `.codex/agents/*.toml` — auto-discovered? (CLI 0.153.4, 2026-09-07)

Closes half of the `fix_plan` item "Codex hooks follow-up": *"one transcript shows a generated agent
role in use"*. The other half (a `--user` install of the generated `~/.codex/hooks.json`) is **not**
done — see "Still open" below, which also records the cheaper way to do it.

## Verdict

**`.codex/agents/*.toml` is a discovered directory, not a manifest.** A role file needs no entry in
`config.toml`. The harness generator emits seven role files and no `[agents]` block, and a real
`codex exec` session named all seven. A discovered role also **actually runs**: one spawned by name
returned a token that exists nowhere but inside its own instructions. **The generator needs no
change.**

Rounds 2 and 3 exist because the fresh-context review found three round-1 claims stated as measured
with nothing committed behind them. Producing the artifacts **overturned one of them** — see
"Corrections" below. The central finding survived unchanged.

## What was measured

Environment: `codex-cli 0.153.4`, project = a worktree under `c:\users\<you>\repos\<repo>`, which is
trusted by prefix through the existing `[projects.…]` entry (arm 0 asserts this; without trust Codex
skips the whole `.codex/` layer and every arm would read as "not discovered" for the wrong reason).
Nothing was written to `~/.codex`. Every arm is one real model call.

| Arm | Setup | Result | What it settles |
|---|---|---|---|
| A | Role **declared** in `config.toml`, `config_file` → a missing file | `warning: Ignoring malformed agent role definition: agents.probeA.config_file must point to an existing file at …` | Positive control: the project config layer **is** read, and the loader has a voice |
| B | **Malformed** role file in `.codex/agents/`, declared **nowhere** | `warning: Ignoring malformed agent role definition: agent role file at …\probeB.toml must define \`developer_instructions\`` | **The finding.** The loader read a file it was never pointed at ⇒ the directory is auto-discovered |
| C | The **same** malformed file, now declared via `config_file` | *no warning at all* | Content is validated on the discovery path, not the declaration path |
| D | Well-formed role, declared | Session listed `probeD` | Roles reach the model — but D was both well-formed *and* declared, so it does not isolate discovery |
| E | Well-formed role, **undeclared** (the shape codex-setup emits) | Session listed `probeE` (plus names with no files behind them — see G3) | Discovery alone makes a role **visible** |
| F | The **real** generated set (`harness/codex-setup.sh`, plugin 0.3.9) | Session listed all seven generated names | The generated files reach a session |
| G1 | The arm-B state, under `codex doctor` | Doctor **does** report it, as a `startup warning` at line 121 | Overturns a round-1 claim |
| G2 | `CODEX_HOME` → an empty directory | Config, log dir, `auth.json` and six SQLite DBs all under the new home; only failure is missing auth | The `--user` probe needs no machine-wide write |
| G3 | No project `.codex/` at all, same question **twice** | `general-purpose` both times | The enumeration is partly **confabulated** — see below |
| H1 | Undeclared role whose instructions carry a unique token, **spawned** | `XYZZY-ROLE-TOKEN-4417` returned verbatim | A discovered role is genuinely **in use** |
| H2 | `CODEX_HOME` **under** the system temp dir | `Refusing to create helper binaries under temporary dir` | Constraint on the still-open probe |

Raw output: `probes/results-raw.txt` (arms 0/A–D), `probes/results-visible.txt` (E, and F's first
failed attempt), `probes/results-visible-real.txt` (F), `probes/results-round2.txt` (G1–G3),
`probes/results-round3.txt` (H1–H2). The two `*-assertions.txt` files are re-runs with
`PROBE_SKIP_MODEL=1`, which exercise the corrected pass/fail logic for free.

Probes are re-runnable, but the arms that call `codex exec` are real model calls — set
`PROBE_SKIP_MODEL=1` to run only the free parts, and do not loop them.

*Reading `results-round2.txt` and `results-round3.txt`: both raw files end an assertion with a
verdict line that contradicts the matching lines printed directly above it — `(no matching lines)` in
round 2, `(no refusal line …)` in round 3.* Those are the raw first runs, and the contradiction is the very defect
described below — a `grep` whose `||` fallback fires because `codex doctor` exited non-zero under
`pipefail`, not because the grep failed. Read the matching lines, not the verdict. The corrected
logic and its output are in the two `*-assertions.txt` files, which print `(MATCHED …)`.

## Method note — why a *malformed* file

A well-formed role that is silently ignored and one that loaded look identical from outside. The
oracle has to be a file the loader will complain about, so its own error names the path it read. Arms
A and C are the controls that prove the oracle fires in this environment; without them arm B's
warning could be read as noise and arm E's success as the model confabulating a plausible name.

## Corrections — what rounds 2 and 3 changed

**`codex doctor` is NOT blind to a broken role. Round 1 said it was, in six surfaces.** Under the
malformed-and-undeclared state, doctor carries the identical text as a `startup warning` field at
line 121 of its output (`probes/results-round2.txt`, arm G1). The false claim came from reading only
doctor's first 30 lines — the round-1 script piped it through `sed -n '1,30p'`. This repo ratcheted
exactly that failure on 2026-09-06 ("a filtered grep cannot prove a claim of silence") and it
recurred here a day later, in the work of the session that had just read the ratchet. What survives
is a much weaker, still-useful point: doctor does not raise it in the Notes summary at the top, so
`codex exec` shows it sooner.

**The surrounding role names are partly confabulated, so do not read them as a built-in list.** Round
1 wrote "beside the built-in `default` and `worker`". Asked with no project `.codex/` at all, the
model answered `general-purpose` twice (arm G3); other arms volunteered `default`, `explorer` and
`worker` with no such files on disk. The names that track the files exactly are the probe roles and
the seven generated ones — those never appear in the empty baseline — so the enumeration is
corroborating, not load-bearing. The load-bearing evidence is the loader's own warning (arm B) and
the spawn token (arm H1).

**"Spawnable" was an inference; now it is measured — twice.** No round-1 arm spawned anything, and an
enumeration of names is not use, which matters because G3 showed the model will produce names for
roles that do not exist. Arm H1 spawned a discovered, undeclared role and got back
`XYZZY-ROLE-TOKEN-4417`, a string in exactly one file on disk. A name can be invented; that token
cannot. But H1 alone still did not prove the loader delivered it — its prompt did not forbid file
reads, and the role file sat in the cwd, so a parent that read it gives an identical transcript.

Round 4b (`probes/results-round4b.txt`) closes that. Reads forbidden, one role file, two placements:

| Arm | Role file at | Reply |
|---|---|---|
| L1 | `.codex/agents/` (discovered) | `PLUGH-CONTROL-TOKEN-8823` |
| L2 | `.codex/agents-off/` (same bytes, undiscovered, still on disk) | `NO-SUCH-ROLE` |

The token is present on disk in both arms and comes back in only one. Discovery is the delivery
mechanism.

**On the fix_plan clause "one transcript shows a generated agent role in use":** it is closed by
three arms together, not by any one. Arm B shows the loader reads an undeclared file; arm F shows the
*generated* seven reach a session; L1/L2 show a discovered role genuinely runs and does so via
discovery. No single arm both spawns and uses a file the generator itself wrote — the spawn probes
use a hand-written role so the token can be unique.

**Six SQLite databases, not five,** under a redirected `CODEX_HOME` (arm G2).

## Two things worth keeping

1. **A malformed role is a warning, not a fatal.** The session ran to completion and answered
   normally. Unlike the V3 `config.toml` defects (which killed the whole project layer), a bad role
   file degrades silently: the role is simply absent, and only the warning line says so.
2. **`[agents.<name>]` in `config.toml` is a separate, weaker mechanism.** `AgentRoleToml` takes
   `description`, `config_file`, `nickname_candidates` — the binary's own deserializer error says
   `struct AgentRoleToml with 3 elements` and names them (`probes/results-round4.txt`). A missing `config_file` warns; a *malformed*
   declared file does not (arm C). The harness does not use declarations and, on this evidence,
   should not start.

## Three self-inflicted process failures in this run

Recorded because they are cheaper to read than to repeat, and they are in `AGENT_NOTES.md`:

- **A filtered view was used to prove silence** — the `codex doctor` claim above. The single most
  expensive error here, because it shipped as fact into six surfaces and only the fresh-context
  review's refusal to accept an uncited claim caught it.

- **Run 1 died to SIGPIPE.** The script was piped `| tee results.txt | head -120`; head closed the
  pipe, tee took the signal, and the script stopped two arms early with a results file that just
  looked short. Same family as the guard-hook fail-open this repo ratcheted twice — self-inflicted
  this time, and it wasted the model calls it had already paid for.
- **Arm F's first attempt never reached Codex.** `harness/codex-setup.sh` exited with
  `lean-agent-harness engine not found`: nothing auto-sets `HARNESS_ENGINE` for a bare wrapper call,
  so it fell through to the `~/.claude/plugins` cache — **0.2.9, from 2026-08-12**, which predates
  codex-setup entirely. Re-run with `HARNESS_ENGINE=<worktree>/plugin/engine`
  (`probes/role-visible-real.sh`).

## Path scrubbing

The transcripts are full of machine-local home paths, which this public repo's pre-commit guard
blocks. `probes/scrub-paths.sh` normalizes them to `<you>`/`<repo>`; `probes/scrub-proof.sh` asserts
it actually substitutes. That proof exists because the scrubber was rewritten mid-run — the first
version carried the home path as a literal, which made the scrubber itself unstageable — and by then
the files were already clean, so the rewrite printed `scrubbed` three times having changed nothing.
The proof planted a dirty fixture and immediately found a real defect: the rewrite derived the repo
name from `git rev-parse`, so a copy running in a temp dir died with `fatal: not a git repository`.
It now derives from the script's own path, with env overrides for the proof. A tool that silently
does nothing looks exactly like a tool that works.

## Still open — the `--user` hooks half

Not done here: whether a `--user` install of the generated `~/.codex/hooks.json`, with its
`_generated_by` and `_shell_matcher_note` top-level keys, fires `hook: SessionStart`.

It does **not** need the machine-wide write that has blocked it twice. `CODEX_HOME` redirects the
entire user-level layer (arm G2): with it pointed at an empty directory, `codex doctor` reported
config, log dir, `auth.json` and six SQLite databases all under the new home, and the only failure was
`✗ auth  no Codex credentials were found — Run codex login or provide an API key through a supported
auth env var`. So the probe is a throwaway home plus the generated `hooks.json` plus auth, then one
`codex exec`, with the real `~/.codex` untouched.

Two constraints for whoever runs it. The throwaway home needs auth — a copied `auth.json`, or that
API key env var; **copying a live token into a scratch directory is the operator's call, not the
agent's**, which is why this run stopped here. And the home must not sit under the system temp dir:
arm H2 put one there and Codex emitted `Refusing to create helper binaries under temporary dir` and
carried on without PATH aliases.
