# E2E evidence — `harness-migrate`

Date: 2026-07-14. Task: build the plugin-shipped `harness-migrate` tool (execution plan
`docs/execution-plans/2026-07-14-harness-migrate.md`). Full transcript: `raw-run.txt` (this dir).

## What was exercised
A synthetic **copied-in harness** was built in a temp dir carrying one file of each class, then the
real `plugin/engine/migrate.sh` was run against it — first the default **report**, then **`--apply
--replace-runners --force`**. (The PS twin, `migrate.ps1`, is covered by `migrate-test.ps1`; both
mirror tests pass 42/42.)

Synthetic repo contents:
- IDENTICAL (copied verbatim from the plugin): `.claude/agents/explorer.md`,
  `.claude/skills/e2e-evidence/SKILL.md`, `.claude/hooks/protect-specs.sh`, `harness/lib/gate.sh`.
- DIFFERS (a ratchet): `.claude/hooks/block-destructive.sh` with an extra denylist line appended.
- PROJECT-ONLY: `.claude/skills/proj-thing/SKILL.md`.
- Runners: `harness/loop.sh` + `harness/fleet.sh` (copied engine scripts + a local tweak → DIFFERS).
- `.claude/settings.json`: engine hooks (`block-destructive`, `session-start`) + one **project**
  hook (`project-notify.sh`) + `model` + `permissions`.
- Never-touched scaffold: `CLAUDE.md`, `harness/harness.config.json`, `state/`, `specs/`.

## Classification (report, no flags — writes nothing)
```
IDENTICAL to plugin (safe to remove) — 4 file(s):
  - .claude/agents/explorer.md
  - .claude/skills/e2e-evidence/SKILL.md
  - .claude/hooks/protect-specs.sh
  - harness/lib/gate.sh
DIFFERS (KEPT for review) — 1 file(s):
  ~ .claude/hooks/block-destructive.sh
      108a109
      > # RATCHET: block terraform destroy (added by this project)
PROJECT-ONLY (KEPT — yours) — 1 file(s):
  + .claude/skills/proj-thing/SKILL.md
```
The report ends with "nothing was written"; the IDENTICAL files were confirmed still present.

## `--apply` result (acceptance criterion 2)
- **Ratchet preserved:** `.claude/hooks/block-destructive.sh` is still present and byte-for-byte
  unchanged (the appended denylist line survives).
- **Project skill preserved:** `.claude/skills/proj-thing/SKILL.md` still present.
- **IDENTICAL removed:** all 4 IDENTICAL files gone; `harness/lib/` pruned as an emptied dir; the
  `skills/` dir survives because `proj-thing/` remains.
- **settings.json surgery** (post-review behavior — strip only wiring whose FILE was removed): the
  `protect-specs`/`format-and-check`/`lock-config`/`session-start` wiring (IDENTICAL-removed or absent
  files) is gone and emptied events are pruned, **but the `block-destructive.sh` wiring is KEPT** —
  because its file is DIFFERS-kept, so the ratchet keeps firing (it just now runs alongside the plugin's
  stock hook, harmless for a denylist). The **project** hook (`project-notify.sh`), a decoy project hook
  `my-block-destructive.sh` (whose name embeds an engine hook name — left-boundary matching keeps it),
  `model: opus`, and `permissions.allow` all survive — still valid JSON.
- **Runner wrappers installed:** `harness/loop.sh` + `harness/fleet.sh` are now thin wrappers
  (contain `HARNESS_ENGINE`), originals backed up to `*.pre-plugin.bak`.
- **Scaffold untouched:** `harness/harness.config.json`, `CLAUDE.md`, `state/`, `specs/` unchanged.
- **`harness/MIGRATION-REPORT.md`** lists Removed / DIFFERS / PROJECT-ONLY, the settings edits, the
  wrappers, and a **WARN** that the customized `block-destructive` hook's wiring was KEPT and now runs
  alongside the plugin's stock hook — port the change into the plugin, then remove the local copy.
- **Non-git guard:** `--apply` on a non-git target without `--force` is refused (nothing changed).

## Fixes after fresh-context review (FIX-THEN-SHIP → shipped)
The reviewer found four issues, all fixed + covered by new tests (migrate-test now **42/42** each):
1. **(blocking)** wiring is now stripped only for hooks whose FILE was removed; a DIFFERS-kept guardrail
   keeps its wiring (was: strip-all + WARN, which silently disabled a ratcheted security hook).
2. `mapfile` (bash-4) replaced with an awk dedupe — `--apply` no longer crashes mid-surgery on macOS bash 3.2.
3. hook-name matching anchored on BOTH sides — a project `my-block-destructive.sh` is no longer stripped.
4. non-git target: `--apply` refuses without `--force`; the report's reversibility line is conditional.

## Verification gate (all green)
- `powershell -File harness/tests/migrate-test.ps1` → 42 passed, 0 failed.
- `bash harness/tests/migrate-test.sh` (jq on PATH) → 42 passed, 0 failed.
- `powershell -File harness/tests/run-tests.ps1` → **69** passed, 0 failed (was 68 + the folded migrate self-test).
- `bash harness/tests/run-tests.sh` (jq) → **65** passed, 0 failed (was 64 + folded).
- `powershell -File harness/tests/fleet-queue-test.ps1` → 16 passed, 0 failed; `bash …fleet-queue-test.sh` (jq) → 16 passed.
- Static: `[Parser]::ParseFile` PARSE OK on `migrate.ps1` + `migrate-test.ps1` (both carry a UTF-8 BOM);
  `bash -n` SYNTAX OK on `migrate.sh` + `migrate-test.sh` (LF, no CR).
