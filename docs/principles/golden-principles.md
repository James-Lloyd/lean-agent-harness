# Golden principles

Taste invariants for *this* project — the things both humans and (where possible) linters enforce.
This is the single source for subjective preferences, so the agent doesn't guess. `/harness-init`
seeds it from the interview; it grows via `/ratchet`. Keep each principle short and, ideally, mechanizable.

> Rule of thumb: if a principle here can be checked by a linter/test/hook, encode it as one and make
> the failure message state the fix. Prose is the fallback for what can't (yet) be mechanized.

## Code
- Prefer a shared utility/package over a hand-written helper that duplicates it.
- Functions and files stay small enough to hold in your head; split when they don't.
- Names say what, not how; no abbreviations that aren't already idiomatic in this repo.
- Match the surrounding code's style, idioms, and comment density. New code should be unrecognizable
  as "the new code."

## Structure
- Dependencies flow one direction (see `docs/architecture/`). No reaching across layers.
- Cross-cutting concerns enter through a single, explicit seam — not sprinkled everywhere.

## Tests & verification
- A test that can't fail is worse than no test. Assertions must be able to go red.
- Never weaken or delete a test to make a build pass.
- Unit-green is not done — every change carries end-to-end evidence (see the `e2e-evidence` skill).

## Errors & logging
- Fail loud and specific; no silently-swallowed errors.
- Structured logging over `print`/`console.log` spew.

## Anti-slop (where quality is visible)
- A coherent whole over a collection of parts. No template defaults left as-is where the product is
  user-facing. Originality and craft over the first generic thing that compiles.

<!-- Add project-specific principles below as they're established. Delete any that stop earning their place. -->
