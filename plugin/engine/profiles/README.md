# Stack profiles

A **stack profile** is a small JSON file that tells the harness *what* the verification-gate steps
mean for a given tech stack. The harness core defines **when** the gate runs (on edit, each loop
iteration, before commit); the profile defines **what** `format` / `lint` / `typecheck` / `test` /
`build` / `e2e` actually are. That separation is what lets one harness span any stack.

## How it's used
1. `/harness-init` runs the `stack-detect` skill, which inspects the repo (lockfiles, manifests,
   config) and either matches an existing profile here or **generates a new one** by interview.
2. The chosen profile's `gate` block is merged into the relevant **`components[].gate`** in
   `harness/harness.config.json` (each component references its profile by name); any cross-cutting e2e
   that exercises components together goes in the top-level `gate` (the root cross-cutting gate). The
   commands are also written into `CLAUDE.md` and `AGENT_NOTES.md`.
3. The loop and the Claude Code hooks then run those commands. Nothing in the core references a
   specific language.

## This directory is intentionally sparse
Per the project's "keep it generic" decision, we do **not** ship an exhaustive matrix of stacks.
`_template.json` is the canonical shape; `node.json` and `python.json` are reference examples that
demonstrate the fields. Add or generate profiles as you actually encounter stacks — the ratchet
applies here too. To add one, copy `_template.json`, fill it, and reference it by name from config.

## Fields
See `_template.json` for the annotated shape. Any gate command may be `null` to skip that step
(e.g. a dynamically-typed project with no `typecheck`).
