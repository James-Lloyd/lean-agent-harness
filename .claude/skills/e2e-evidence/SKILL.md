---
name: e2e-evidence
description: Capture real end-to-end evidence that a change works as a user experiences it, not just that unit tests pass. Use before marking any task done and during /verify and /review.
---

# e2e-evidence

Unit-green is not done. A large fraction of "all tests pass" changes are still broken in the real
product. This skill captures the proof a skeptical human would accept, matched to the stack. Save
artifacts under `state/evidence/<task-id>/` so review and the human can see them.

## Choose the proof for the interface
- **Web / UI** — drive the running app with the Chrome MCP (or Playwright): perform the real user
  flow, then screenshot the working state. Capture the console/network if relevant. The screenshot is
  the evidence.
- **HTTP API / service** — make the actual request(s) against a running instance. Capture method+URL,
  status, response body (schema-checked), and any side effect (row written, event emitted). Check logs
  or metrics for errors.
- **CLI** — run the real command with realistic input; capture the exact invocation, stdout/stderr,
  and exit code. Include a failure-path run if the change touches error handling.
- **Library / SDK** — write a tiny throwaway driver that calls the public API as a consumer would;
  capture its output. (Then delete the driver or fold it into tests.)
- **Data / batch / ML** — run on a real or realistic sample; show input → output (row counts,
  artifacts, a spot-checked record), not just "the job exited 0".
- **No automatable surface** — record the manual steps performed and their observed result explicitly.

## Standard
- Evidence must show the **actual changed behavior**, end to end — not a mock, not a unit test, not
  "should work."
- Tie each piece of evidence to a specific acceptance criterion in the relevant `specs/`. Only tick a
  criterion the evidence *demonstrates*.
- If you cannot produce evidence, the task is not done — say so and either build the missing harness to
  produce it or escalate.

## Output
A short evidence note: what you exercised, the artifact path(s), and which acceptance criteria are now
demonstrably met (and which remain unproven).
