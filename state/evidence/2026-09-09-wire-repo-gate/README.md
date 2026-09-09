# 2026-09-09 — wire the repo's own gate into `harness.config.json`

**Task:** `state/fix_plan.md` — *"Wire the repo's own gate into `harness.config.json`
(from /harness-doctor 2026-09-07, check 4)"*. Every gate step was `null`, so `/verify` and the loop's
`autoRollbackOnRed` graded an **empty command set** while the repo's real 364/371-assertion suites sat
unreferenced.

**Change:** `components[0].gate.test` = `node harness/tests/gate.mjs`, a new cross-shell dispatcher
that runs both self-test twins; plus assertions in both suites pinning the wiring.

**The judgement call in the task text is resolved, not dodged.** The item allowed either wiring the
gate *or* documenting all-null as the shipped-template default, on the grounds that this file is also
the consumer template. It **is** that template — the plugin doesn't ship `harness.config.json`
precisely because a consumer *clones this repo* for the scaffold (`README.md` Quickstart) — so the
argument for wiring it cannot be "this file is only ours". The real argument is that nothing depends
on it staying null: `/harness-init` **rebuilds** `components[].gate` from the consumer's own stack as
step 3 of setup, so a clone inherits this gate only for as long as it has not run setup, and the new
`_comment` tells that reader all-null is their correct starting shape. Meanwhile the cost of leaving
it null is paid every day in *this* repo, where the gate is the product.

---

## Why the gate command is a `.mjs` and not a shell script

A gate step in `harness.config.json` is **one string**, and the engine hands it to a *different shell
per platform*: `cmd /c <cmd>` in `plugin/engine/lib/gate.ps1` (`Invoke-GateStep`), `bash -lc <cmd>` in
`gate.sh` (`_gate_step`). Three spellings were tried; the first two fail by inspection, the third
failed **live** and is the reason this file exists:

| candidate | verdict |
|---|---|
| `harness/tests/run-tests.ps1` | cmd.exe refuses a forward-slash command path — measured: `'harness' is not recognized as an internal or external command`. Backslashes then break under `bash -lc`. |
| `powershell … -File …` | no `powershell` on Linux. |
| `bash harness/tests/gate.sh` | **measured red.** Under `cmd /c`, `bash` is **WSL's** `C:\Windows\System32\bash.exe` — Git Bash is only on PATH *inside* a Git Bash session. On this box (no WSL) the gate died with `HCS_E_HYPERV_NOT_INSTALLED`; on a box *with* WSL it would have silently run the suite in another OS against another filesystem view, which is worse. → `arm 0`, `wsl-trap.txt` |
| `node harness/tests/gate.mjs` | **shipped.** `node` resolves under both shells (`where node` → `C:\Program Files\nodejs\node.exe`), it is already a harness dependency (`plugin/hooks/run.mjs` exists for exactly this reason), and node resolves paths itself, so the platform dispatch is written once in a real language instead of encoded in a config string. |

`gate.mjs` runs the platform's **native** twin fail-closed. On Windows it also runs the `.sh` twin,
locating Git Bash **by path on disk** (`%ProgramFiles%\Git\bin\bash.exe`, plus a path derived from
`git --exec-path`) — never by a `PATH` lookup, which is the trap above. On POSIX it does **not**
attempt the `.ps1` twin even when `pwsh` exists. That is a decision, not a measurement: that suite
does choose its host (`$PSVersionTable.PSEdition` → `pwsh`/`powershell`), but nothing in CI has ever
run it off Windows, so its POSIX behaviour is unknown and a red from it would say nothing about the
change under test.

Any ungraded twin prints a loud `!!! UNGRADED TWIN` banner naming CI as the backstop. **Where that
banner is actually seen is narrower than "always", and the first draft of this file overstated it:**
both engines print a gate command's output *only when it exits non-zero* (`Invoke-GateStep`,
`_gate_step`), so under `loop`/`fleet` a green half-graded run is indistinguishable from a fully
graded one. The banner reaches a human under `/verify`, where the agent runs the command itself.
`HARNESS_GATE_STRICT=1` closes the gap for a caller that reads only the exit code — arm 4 measures
both halves.

---

## Arms

| # | what it proves | script | output |
|---|---|---|---|
| 0 | the WSL trap is real, and `node` is not affected | `probes/wsl-trap.ps1` | `wsl-trap.txt` |
| 1 | the **Windows engine path** (`gate.ps1` → `cmd /c`) runs the configured gate green | `probes/engine-gate-ps.ps1` | `engine-gate-ps.txt` |
| 2 | the dispatcher run directly, **full output kept** — where the two RESULT lines are cited from | `probes/engine-gate-sh.sh` | `dispatcher-direct.txt` |
| 3 | the **POSIX engine path** (`gate.sh` → `run_gate` → `bash -lc`) runs the configured gate green | `probes/engine-gate-sh.sh` | `engine-gate-sh.txt` |
| 4 | a **red suite turns the gate red**, and a **half-grade is loud and (under `HARNESS_GATE_STRICT=1`) fatal** — each with a positive control | `probes/red-propagation.sh` (+ `force-env.mjs`) | `red-propagation.txt` |
| 5 | the new suite assertions **fail against every pre-fix / regressed shape** — both twins, with a control | `probes/mutation-check.sh` | `mutation-check.txt` |

Support files: `probes/force-env.mjs` builds the doctored environment arm 4 needs (`env
ProgramFiles=…` cannot: MSYS hands the child the real `C:\Program Files` anyway — measured);
`probes/scrub.mjs` strips the OS username, in every separator form, from each probe's own output
before it is written (AGENTS.md 2026-09-07).

Arm 4 is the one that makes the wiring worth anything: with stub twins it asserts `GATE: RED` and
exit 1 when either twin fails (and when both do), and `GATE: green` + exit 0 when both pass. Without
that green positive control, a `gate.mjs` that crashed for an unrelated reason would satisfy every
red case and prove nothing. Its second half forces the **half-grade** branch through the environment
rather than by editing code — every Git-install candidate pointed at an empty dir, `git` off `PATH`,
`System32`/`WindowsPowerShell`/`nodejs` kept so the `.ps1` twin still runs — and asserts the banner
appears, the exit stays 0 by default, and the exit becomes 1 under `HARNESS_GATE_STRICT=1`. Its
positive control (Git Bash present ⇒ **no** banner) is what makes "banner absent" mean something.

Arm 5 is the mutation check AGENTS.md 2026-09-06 requires: it extracts the `gate wiring` block from
each twin **by marker from the file itself** (never transcribed), refuses to run unless both twins
yield the same non-zero assertion count, and runs each block against scratch trees that differ from
this repo in exactly one way. Three mutants, one control, per twin:

| tree | must |
|---|---|
| `gate.test = null` (the shape the doctor found) | FAIL |
| the whole `gate` object deleted | FAIL — *not* crash; this is the shape that used to abort the PS suite on a missing property |
| `gate.mjs` mutated so `findBash` calls `which('bash')` **before** its `!WIN` guard | FAIL, and the failure must NAME the WSL-trap assertion |
| nothing changed | PASS, all 6 |

A block that crashes instead of failing is reported as a crash, not a pass — and that distinction
earned its keep twice while building this arm.

**Arm 5 found three real defects in this change's own test code.**
1. The PS path assertion was `Test-Path (Join-Path $gwRoot $gwScript)`; on a null `gate.test` that is
   `Join-Path <root> ''` → the repo root, which exists → it **passed on the exact shape it exists to
   catch**. Fixed with a non-empty guard and `-PathType Leaf`.
2. The WSL-trap assertion grepped the whole file for `if (!WIN) {` and `existsSync` — tokens the
   mutant above still contains, so it could not accuse. It now asserts the **position** of the single
   `which(` call inside `findBash`, and the mutant proves it goes red.
3. The arm's own PS harness did not dot-source the engine's `gate.ps1`, so `Get-Prop` was missing and
   the three config assertions silently **never ran** — pass=3, fail=0, reported green. Fixed by
   matching the real suite's preamble.

Provenance, since it is the point: (1) was found by the arm itself, before review; (2) was found by
the fresh-context reviewer reading the assertion; (3) was found only by *running* the arm after the
reviewer's fix — the review that demanded a mutant could not have seen it.

## Results

All five arms green, every one of them re-run against the **final** files after the fresh-context
review's fixes landed (two earlier passes were discarded: one because the suites were edited
mid-run, one because the review changed the probes themselves).

| # | result | cited from |
|---|---|---|
| 0 | `cmd /c where bash` -> `C:\Windows\System32\bash.exe` (+ the WindowsApps stub). `cmd /c bash -c "echo from-bash"` -> `WSL2 is unable to start ... HCS_E_HYPERV_NOT_INSTALLED`, exit 1. Controls: the same lookup inside Git Bash gives `/usr/bin/bash` + `MINGW64_NT-10.0-26200` and prints `from-bash`; `where node` -> `C:\Program Files\nodejs\node.exe` and `node -e` prints `from-node`, exit 0. | `wsl-trap.txt` |
| 1 | `Passed=True FailedStep='' Component=''`, **258 s**. Negative control (gate.test -> a command that exits 1): `Passed=False FailedStep='test' Component='root'`. | `engine-gate-ps.txt` |
| 2 | dispatcher direct, exit 0, **262 s** — `run-tests.ps1` **377 passed, 0 failed**; `run-tests.sh` **370 passed, 0 failed**; `GATE: green (both twins)`. | `engine-gate-sh.txt`, full 900-line capture in `dispatcher-direct.txt` |
| 3 | `run_gate` exit 0, `failed_step=''`, **344 s**, log line `- test : node harness/tests/gate.mjs`. Negative control: exit 1, `failed_step='root:test'`. | `engine-gate-sh.txt` |
| 4 | red: both-fail / ps-only / sh-only all exit 1 + `GATE: RED`; green control exit 0. Half-grade: no Git Bash -> banner + exit **0**; same with `HARNESS_GATE_STRICT=1` -> banner + exit **1**; control (Git Bash present) -> **no** banner, exit 0. | `red-propagation.txt` |
| 5 | extraction guard `sh 6 / ps 6`; per twin — `gate.test=null` fails 3/6, `gate` object deleted fails 3/6, mutated `gate.mjs` fails 1/6 **naming the WSL-trap assertion**, control passes 6/6. Both twins identical. | `mutation-check.txt` |

Suite counts before this change were **371 (PS) / 364 (bash)**; the +6 each are the new `gate wiring`
assertions, visible under that heading in both twins in `dispatcher-direct.txt`.

A full both-twin gate measured **258–344 s** across the runs above (~4–6 min); the first cold run of
the day was ~9 min.

## Regression cover added to the suites

Both twins gained a `gate wiring` section (mirrored, `run-tests.sh` / `run-tests.ps1`):

- `components[0].gate.test` is non-null — the wiring cannot quietly revert to the all-null shape;
- it launches via `node` — pins the *cross-shell* property, with the WSL measurement cited in the
  comment so the next reader does not "simplify" it back to `bash …`;
- the script it names exists at that repo-relative path;
- `gate.mjs` exists and parses (`node --check`);
- `gate.mjs` keeps its `bash` PATH lookup behind the `!WIN` guard.

The PS twin reads config keys through `PSObject.Properties[...]` (AGENTS.md 2026-08-06: a bare
`$obj.$key` on a missing key aborts the whole suite under StrictMode instead of failing one
assertion).

## Residuals (stated, not hidden)

- **`gate.mjs`'s POSIX branch has never executed anywhere.** Every arm here ran on Windows — arm 3
  exercises the *engine's* POSIX gate router (`run_gate` → `bash -lc`) under Git Bash, but node still
  reports `win32` inside it, so the dispatcher takes its Windows branch there too. `which('bash')`
  with `shell:true`, `findPowerShell() → null`, and the POSIX ungraded-`.ps1` banner are unexercised.
  CI runs the twins directly rather than through the dispatcher, so it does not cover them either.
- **The dispatcher's Windows branch is exercised locally, not in CI.** CI keeps running each twin
  directly per OS (unchanged: `.sh` on ubuntu, `.ps1` on windows), and the suite's assertions on
  `gate.mjs` are parse- and position-level. A Windows-only regression inside `gate.mjs` would be
  caught by the next local gate run, not by CI.
- **Cost:** a full both-twin gate measured 258-344 s across the runs recorded above (~4-6 min; ~9 on the first cold run). That is the honest
  price of grading the real suites every iteration; it was previously ~0 because nothing ran.
- On a POSIX host the gate grades one twin and says so. That matches `/harness-doctor` check 7, which
  also runs "the suite for the current platform".
