# Sandboxing for unattended runs — execution plan

_Authored 2026-07-15. Task: `state/fix_plan.md` → "Sandboxing for unattended runs (ROADMAP
"Sandboxing")". Single iteration. Component: `root` (touches `plugin/engine/` + docs + tests)._

## Problem
`mode: auto` runs the model unattended. Today the loop's only defense for that case is a **printed
warning** ("run inside a sandbox/container") on `auto + skipPermissions` — but the loop cannot tell
whether it is *actually* inside one, so the advice is unenforced and easy to ignore. ROADMAP →
"Sandboxing for unattended runs" calls for a documented container/VM profile plus loop-side detection.
On Windows there is no native sandbox, so the supported path is WSL2 / devcontainer.

## Sprint contract: Sandboxing for unattended runs

### Scope (this sprint)
- A **sandbox-detection** predicate in the engine (`Test-Sandboxed` / `is_sandboxed`, in
  `plugin/engine/lib/gate.{ps1,sh}`) — pure, no jq, unit-testable on both runners.
- A **loop startup guard**: when `autonomy.mode == auto` **and** the run is **not** sandboxed, print a
  loud warning pointing at the profile doc. (Warn only — `confirm_checkpoint` is a no-op in auto by
  design, so an unattended run is never blocked/hung; consistent with the sibling skipPermissions guard.)
- A **documented, tested profile**: `docs/sandboxing.md` (the human-facing guide) + a shipped template
  `plugin/engine/templates/devcontainer.json` that a project copies to `.devcontainer/devcontainer.json`.
  The profile encodes: `specs/` read-only, secrets via env only (not baked into the image), no host FS
  bind (workspace in a container volume), ephemeral — and it exports `HARNESS_SANDBOX=1` so the loop
  recognizes it.
- **Unit tests** (both runners) for the predicate; a **JSON-validity test** for the template.
- E2E: drive `loop.sh --dry-run` in a temp git repo with a `mode: auto` config — assert the warning
  appears with `HARNESS_SANDBOX` unset and is absent with `HARNESS_SANDBOX=1`.

### Out of scope
- Actually building/running a container in CI (no Docker on the runners). The devcontainer.json is
  validated as JSON + documented; a live container build is a supervise-first follow-up (like the codex
  write path).
- Changing the `skipPermissions` deny-list semantics, or adding network-egress enforcement (documented
  as a profile property, not enforced by the engine).
- Treating bare WSL2 as sandboxed automatically — WSL2 with `/mnt/c` has host-FS access, so the WSL2
  path is opt-in via `HARNESS_SANDBOX=1` after cloning into the WSL-native FS (documented).

### Detection contract (the design)
`HARNESS_SANDBOX` env var is the **explicit contract** the profile sets:
- Truthy (`1`/`true`/`yes`, case-insensitive) → sandboxed.
- Falsy (`0`/`false`/`no`) → **not** sandboxed (explicit override, also how tests force the negative).
- Unset → fall through to **auto-detect** common container markers (convenience so a devcontainer "just
  works" even if the user forgot to set it): `/.dockerenv`, `/run/.containerenv` (podman), or the marker
  env vars `$CODESPACES` / `$REMOTE_CONTAINERS` / `$DEVCONTAINER` / `$container` **being set (present) —
  not truthy**, since a runtime injects them to signal itself (`$container` holds a runtime NAME like
  `lxc`), or `docker|containerd|lxc|kubepods` in `/proc/1/cgroup`. None present → not sandboxed.
Auto-detect only ever flips to **true**; the explicit var can force either way and always wins.

### Definition of done (every box must be ticked)
- [ ] `Test-Sandboxed` / `is_sandboxed` exist in `gate.{ps1,sh}`, implementing the contract above.
- [ ] Loop guard added to `loop.{ps1,sh}`: `mode==auto && !sandboxed` → loud warning citing
      `docs/sandboxing.md`; no behavior change when sandboxed or when mode≠auto.
- [ ] `plugin/engine/templates/devcontainer.json` exists, is valid JSON, sets `HARNESS_SANDBOX=1`,
      mounts `specs/` read-only, takes secrets via env, uses a volume workspace (no host bind).
- [ ] `docs/sandboxing.md` documents both paths (devcontainer + raw WSL2), the security properties, how
      detection works, and the warning users will see outside the profile.
- [ ] Unit tests on BOTH runners cover: truthy env → true, falsy env → false, unset+no-markers → false,
      truthy variants; plus template-parses-as-JSON.
- [ ] Verified end-to-end with evidence: `loop.sh --dry-run` temp-repo run showing warn-present (unset)
      vs warn-absent (`HARNESS_SANDBOX=1`); `Test-Sandboxed` both branches on the PS side.
- [ ] Gate green: both test suites (`run-tests.{ps1,sh}` + `fleet-queue-test.{ps1,sh}`).
- [ ] No tests weakened; no specs edited.

### How success is verified
```
# unit + template-JSON tests
powershell harness/tests/run-tests.ps1        # expect prior baseline + new sandbox tests, 0 fail
bash harness/tests/run-tests.sh               # (jq on PATH) same
# guard e2e (bash): temp repo, mode:auto config
#   HARNESS_SANDBOX unset  -> stdout contains the "outside a sandbox" warning
#   HARNESS_SANDBOX=1      -> warning absent
```
