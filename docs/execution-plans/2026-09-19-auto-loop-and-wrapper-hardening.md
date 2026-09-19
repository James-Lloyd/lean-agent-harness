# Auto-loop and wrapper hardening

## Sprint contract: harness 0.5.3

### Scope

- Stop both headless loop twins immediately after a green iteration when `commitOnGreen=false`, so a later checkpoint or rollback cannot erase accepted uncommitted work.
- Make the auto/e2e warning describe whether the runner will commit or leave work for a human.
- Extend harness-doctor to flag unsafe multi-iteration/no-commit configurations and incomplete or stale consumer wrapper sets.
- Make all six wrappers resolve the active installed plugin version deterministically instead of selecting an older cache by modification time.
- Bump every shipped plugin version surface to 0.5.3 and refresh the native Codex/Claude installations.
- Migrate three existing consumer repositories without losing project configuration; initialize the fourth consumer only after its routing choice is resolved.

### Out of scope

- Changing consumer product code, gates, autonomy policy, or existing model routing except where the operator explicitly chose it.
- Enabling automatic commits, automatic rollback, deployment, or production promotion.
- Cleaning unrelated dirty trees or deleting historical plugin caches.

### Definition of done

- [x] A mutation-style regression proves the pre-fix loop can enter a second iteration with uncommitted green work, and both fixed twins stop after the first.
- [x] Warning tests cover both `commitOnGreen=true` and `false`.
- [x] Doctor text and twin tests diagnose `maxIterations>1 && commitOnGreen=false`, missing wrappers, and wrappers that differ from the installed plugin.
- [x] Wrapper tests prove the highest semantic version wins across both cache roots even when the older version has the newer timestamp.
- [x] Plugin manifests, marketplace surfaces, generated skills, and validation agree on 0.5.3.
- [ ] Real migrated/initialized consumers dry-run through 0.5.3 without altering their product code.
- [ ] End-to-end evidence is stored under `state/evidence/HARNESS-053-AUTO-WRAPPERS/`.
- [x] Both root gate twins pass; no tests or specs are weakened.
- [ ] A fresh-context reviewer returns SHIP before merge.

### How success is verified

Run `node harness/tests/gate.mjs`, the focused loop/wrapper mutation probes recorded in the evidence directory, plugin package validation, each consumer's `codex-setup --check` when Codex surfaces apply, and a real `loop -DryRun` from each clean migration worktree.
