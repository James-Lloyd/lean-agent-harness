The package structure is broadly sound: manifests parse, command skills synchronize, hook manifests are host-correct, wrapper twins match byte-for-byte, scripts parse, and `AGENTS.md` is 3,397 bytes/60 lines. The standard manifest and bundled-hook layout also agrees with the current [OpenAI plugin packaging](https://developers.openai.com/plugins/build/plugins) and [Codex hooks](https://learn.chatgpt.com/docs/hooks) documentation. I accept the measured Codex 0.154 plugin-hook discovery failure as an upstream limitation.

Findings:

- `plugin/commands/harness-init.md:83` — **BLOCKER** — The advertised Codex `$harness-init` path still determines plugin installation exclusively with `claude plugin list`. On a Codex-only consumer this selects the copied-engine branch, can omit wrapper installation, and may rewire `.claude` hooks. The invoked `plugin/skills/model-routing/SKILL.md:20` also requires the main session to be Claude. The adapter does not translate either substantive assumption. Add an explicit Codex-host branch based on the installed skill root/plugin state and test initialization without Claude installed.

- `plugin/engine/codex-setup.ps1:339` and `plugin/engine/codex-setup.sh:308` — **BLOCKER** — Legacy `--user` ownership accepts any `_generated_by` property, so another tool’s hook file carrying that key can be overwritten wholesale. Conversely, `plugin/scripts/install-codex-hooks.mjs:10` does not recognize the value historically emitted by these generators, and neither mechanism recognizes the other’s new description marker. Define one exact shared ownership/migration predicate and add foreign-marker plus cross-migration tests.

- `state/evidence/2026-09-13-codex-native-plugin/probe.ps1:39` — **BLOCKER** — The fallback live-fire directly exercises the worktree dispatcher and assumes user-hook activation before it starts. The active user hooks point to this worktree; `--check` from the installed 0.5.0 cache reports `STALE`, while the worktree checker reports fresh. Thus the evidence proves installed skills plus worktree-backed hooks, not activation from the installed plugin. Derive the installed cache root, activate from that root, assert every installed command targets it, and then live-fire.

- `state/evidence/2026-09-13-codex-native-plugin/README.md:7` — **BLOCKER** — The evidence records package validators and one session, but no component/root gate result. It also predates later changes to both generator twins, their tests, and `harness-doctor`; the installed cache differs from the current tree. This does not satisfy the explicit exact-tree gate and E2E acceptance criterion in `state/fix_plan.md:12`. Reinstall the final artifact, capture both gate results, and rerun the installed-copy E2E.

- `plugin/scripts/validate-openai-plugin.mjs:101` — **SHOULD-FIX** — “15 skills” is hard-coded and not validated. The package contains 21 discoverable skills: 14 command adapters, activation, and six shared/reference skills. This conflicts with `docs/codex-setup.md:5` and the evidence’s own 21-skill validation claim. Compute and assert the inventory.

- `plugin/scripts/validate-openai-plugin.mjs:67` — **SHOULD-FIX** — Dual-cache wrapper validation checks byte equality and a substring only. It never proves that a consumer with only the Codex cache resolves and invokes the installed engine. Add a cache-only behavioral fixture.

- `docs/design-docs/002-vendor-agnostic-routing.md:88` — **SHOULD-FIX** — The accepted design history stops at project-local command-skill generation and does not record the new native portable-plugin architecture or activation fallback. Add the 0.5.0/native-plugin decision so the architectural authority matches the implementation.

- `plugin/references/codex-command-adapter.md:4` — **NIT** — “Treat source is authoritative” is malformed; use “Treat the source as authoritative.”

No files were modified. The full writable gate could not be independently rerun in this read-only review environment because its validator creates temporary files; the static synchronization, JSON, Node, PowerShell, Bash, and twin-equality checks passed.

VERDICT: FIX-THEN-SHIP
