# Evidence — Plugin E2 flip (dev repo consumes its OWN plugin; in-repo engine copies deleted)

Task: `Plugin E2 flip` (fix_plan). Done-when: this repo installs `lean-agent-harness` from its local
marketplace, its `harness/` is config+wrappers only, and all suites stay green sourced from the plugin.

## What shipped (Part 3 — the destructive flip; Parts 1+2 were prior)
- **Deleted** the in-repo engine duplication (E1): `harness/{lib,profiles,templates,harness.schema.json}`,
  the full-engine `harness/{loop,fleet}.{ps1,sh}`, and `.claude/{agents,commands,skills,hooks}`.
- **Dropped in** the 4 thin wrappers at `harness/{loop,fleet}.{ps1,sh}` (from `plugin/engine/wrappers/`) —
  they locate the engine (`$HARNESS_ENGINE` → `$CLAUDE_PLUGIN_ROOT/engine` → `~/.claude/plugins` search)
  and dispatch passing this repo as project root.
- **Stripped** the 5 engine hook blocks from `.claude/settings.json`; the plugin's `plugin/hooks/hooks.json`
  → `run.mjs` supplies block-destructive / protect-specs / format-and-check / lock-config / session-start.
  Kept `model` + `permissions` (allow/deny/ask incl. `Bash(git push:*)`).
- **Repointed** `$schema` in `harness/harness.config.json` + `examples/headless-fe-be/harness.config.json`
  from the deleted `harness/harness.schema.json` to the plugin copy (`../plugin/engine/harness.schema.json`).
- **Re-pointed** `harness/tests/fleet-queue-test.{ps1,sh}` to `HARNESS_ENGINE=<repo>/plugin/engine` so the
  copied wrapper resolves the engine in the throwaway repo.
- **Doc drift** fixed (from review): `README.md` "What's in the box" table (plugin/scaffold split +
  new `plugin/` row), `.claude/settings.json` `_security_note`, `ci/github-harness-selftest.yml` comment.

Diff: **62 files, +104 / −4490** (`diff-stat.txt`). `harness/` now = `harness.config.json`, the 4
wrappers, and `tests/`.

## Acceptance — all suites GREEN sourced from the plugin (`plugin/engine`)
- PS `run-tests.ps1` → **112/0** (`run-tests-ps.txt`)
- PS `fleet-queue-test.ps1` → **22/0** (`fleet-queue-ps.txt`)
- bash `run-tests.sh` → **103/0** (`run-tests-bash.txt`)
- bash `fleet-queue-test.sh` → **22/0** (`fleet-queue-bash.txt`)

## e2e — wrapper → engine dispatch proven both ways (`wrapper-dispatch.txt`)
`powershell harness/loop.ps1 -DryRun` resolves and boots the engine via:
1. **HYBRID** (`HARNESS_ENGINE` set) → `C:\Users\james\Repos\harness\plugin\engine\lib\checkpoint.ps1`
2. **Discovery** (no override) → `…\.claude\plugins\cache\lean-agent-harness\…\0.2.0\engine\lib\checkpoint.ps1`

Both reach the engine's clean-tree preflight (expected "working tree is dirty" — the flip changes were
uncommitted at capture time), proving the wrapper locates + invokes the real engine, not the deleted copy.

## Review
Fresh-context reviewer (opus — the fable-pinned first attempt hit a Fable-5 usage cap mid-review and was
re-spawned with `model: opus` per the CLAUDE.md ratchet). Verdict: **SHIP**, no blockers. It independently
verified wrapper byte-identity to `plugin/engine/wrappers/`, the installed plugin (0.2.0) resolving on this
machine, guards preserved via the plugin (not silently dropped), all 4 suites green, and no runtime-breaking
dangling refs. Two non-blocking doc-drift nits (README / settings note / ci comment) — all fixed in this commit.
