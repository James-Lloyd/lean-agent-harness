---
description: Run the full verification gate + capture real end-to-end evidence for the current change.
argument-hint: (optional) "<what behavior to prove>"
allowed-tools: Read, Bash, Glob, Grep, Skill, Agent
---

# /verify — prove it actually works

Behavior to prove: $ARGUMENTS

Unit-green is not done. This command runs the full deterministic gate **and** produces user-level
evidence — the kind of proof a skeptical human would accept.

## Procedure
1. **Run the full gate** for each affected **component** (its commands, in its own directory) **and**
   the cross-cutting root `gate` from `harness/harness.config.json`, in order:
   `format → lint → typecheck → build → test → e2e`. Report each. Stop and surface details on the
   first failure (with the fix), but try to report all failing steps if cheap to do so.
2. **Capture end-to-end evidence** appropriate to the stack (use the `e2e-evidence` skill):
   - **Web/UI:** drive it with the Chrome MCP / Playwright; screenshot the working feature.
   - **API/service:** make the real request; capture status + response; check logs/metrics.
   - **CLI/library:** run the actual command/call with realistic input; capture stdout/exit code.
   - **Data/job:** run on a real (or realistic) sample; show the output rows/artifacts.
3. **Compare against acceptance criteria** in the relevant `specs/`. Tick only what the evidence
   actually demonstrates — not what "should" work.

## Output
A short evidence report: gate results (pass/fail per step), the captured evidence (path to
screenshot/log/output), and a clear verdict on whether each acceptance criterion is *demonstrably*
met. Save artifacts under `state/evidence/<task-id>/` so the review and the human can see them.
