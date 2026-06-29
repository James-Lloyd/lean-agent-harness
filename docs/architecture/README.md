# docs/architecture

The map of how this system fits together. The agent reads this **before structural changes** so it
doesn't reinvent or violate the existing shape. Keep it current — a stale architecture doc actively
misleads (the `doc-gardener` watches for this).

Suggested contents as the project grows:
- A one-screen system overview (components and how they talk).
- The **dependency direction** / layering rule, e.g. `Types → Config → Repo → Service → Runtime → UI`,
  with code flowing one way only. Enforce it with a structural test, not prose, where possible.
- Module boundaries and the single seams cross-cutting concerns pass through.
- External dependencies and integration points.

`/harness-init` may seed an initial overview from the interview. Until then this is a placeholder.
