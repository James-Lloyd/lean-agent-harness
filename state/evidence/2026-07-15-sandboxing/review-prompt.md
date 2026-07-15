You are a fresh-context code reviewer. Judge the STAGED DIFF below against the sprint contract. You did
not write this code and have no memory of the conversation that produced it — reason only from the diff,
the contract, and the repo you can read (read-only).

## Task under review
"Sandboxing for unattended runs" in the lean-agent-harness engine. Definition of done:
1. A sandbox-detection predicate `Test-Sandboxed` (PowerShell, `plugin/engine/lib/gate.ps1`) +
   `is_sandboxed` (bash, `plugin/engine/lib/gate.sh`), capability-equivalent. Contract: env var
   `HARNESS_SANDBOX` is the explicit signal and ALWAYS wins when SET — truthy (`1`/`true`/`yes`,
   case-insensitive) => sandboxed; anything else (`0`/`false`/`no`/empty) => NOT sandboxed. Unset =>
   auto-detect container markers (`/.dockerenv`, `/run/.containerenv`, `$CODESPACES`, `$REMOTE_CONTAINERS`,
   `$DEVCONTAINER`, `$container`, `docker|containerd|lxc|kubepods` in `/proc/1/cgroup`); any present =>
   sandboxed. Auto-detect only flips to true; the explicit var wins either way.
2. A loop startup guard in `loop.{ps1,sh}`: when `autonomy.mode == auto` AND not sandboxed => print a loud
   warning citing `docs/sandboxing.md`. WARN-ONLY (no confirm/block — confirm_checkpoint is a no-op in auto
   by design, so it can't block; a plain warning is honest). No behavior change when sandboxed or mode≠auto.
3. Template `plugin/engine/templates/devcontainer.json` — strict valid JSON, `HARNESS_SANDBOX=1`, secrets
   via env (`${localEnv:...}`), no host-FS bind (volume workspace), specs/ read-only.
4. Doc `docs/sandboxing.md` — devcontainer + WSL2 paths, security properties, detection, the warning.
5. Unit tests (both runners) for the predicate + template-is-valid-JSON.

## What to check (scope: correctness + requirement gaps ONLY)
- Does the bash predicate correctly implement the contract, especially the "SET but empty => NOT
  sandboxed" and "explicit falsy beats a present container marker" edge cases? Is `${HARNESS_SANDBOX+x}`
  the right test for "is set (even to empty)"?
- Is the PowerShell `Test-Sandboxed` capability-equivalent (same truthy/falsy/unset semantics)? On Windows
  the /proc + /.dockerenv probes won't match — is that handled without throwing under StrictMode?
- Is the guard placed and gated correctly (mode==auto AND not-sandboxed), and is it genuinely warn-only?
- Is the devcontainer.json strict JSON (no `//` comments) and does it actually satisfy the security
  properties it claims (no host bind, secrets via env, specs read-only)?
- Any regression risk to the existing gate/loop behavior from these additions?
Do NOT nitpick style. Report only correctness bugs, contract violations, or missing done-when items.

End your review with exactly one line: `VERDICT: SHIP` (guardrails intact, criteria met) or
`VERDICT: REJECT` (something is wrong — default to REJECT when unsure). A fix-then-ship should be REJECT
with the specific fix.

## STAGED DIFF
See `state/evidence/2026-07-15-sandboxing/review-input.diff` in the repo (you can read it), or the inline
copy below. Also read the full new files `plugin/engine/templates/devcontainer.json` and
`docs/sandboxing.md` and the current `plugin/engine/lib/gate.ps1` / `gate.sh` for full context.
