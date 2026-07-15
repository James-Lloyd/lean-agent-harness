# Evidence — Sandboxing for unattended runs (2026-07-15)

Maps each done-when box to its proof. All artifacts in this directory.

## 1. Detection predicate — `Test-Sandboxed` (gate.ps1) + `is_sandboxed` (gate.sh)
- Implemented in `plugin/engine/lib/gate.ps1` (`Test-Sandboxed`, `[bool]`) and
  `plugin/engine/lib/gate.sh` (`is_sandboxed`, 0/1). Capability-equivalent, mirror comments on each.
- Contract: `HARNESS_SANDBOX` truthy=`1/true/yes` → sandboxed; `0/false/no/empty` → not (explicit always
  wins); unset → auto-detect markers (`/.dockerenv`, `/run/.containerenv`, `CODESPACES`,
  `REMOTE_CONTAINERS`, `DEVCONTAINER`, `container`, `/proc/1/cgroup` docker/containerd/lxc/kubepods).
- **Proof:** unit tests below cover =1/=true/=yes/=YES → true; =0/=false → false; explicit-0-beats-markers;
  unset+no-markers → false. See `run-tests-bash.txt` / `run-tests-ps.txt` ("sandbox predicate" section).

## 2. Loop startup guard (loop.ps1 + loop.sh)
- Added right after the skipPermissions guard block in both `plugin/engine/loop.sh` and `loop.ps1`.
  WARN-only (no confirm_checkpoint / Confirm-Checkpoint), fires only when `mode==auto` AND not sandboxed.
- **Proof (real loop dry-run, the key e2e):**
  - bash: `guard-e2e-bash.txt` → both PASS. Warning text captured in `guard-bash-unset.txt` (present) and
    absent in `guard-bash-sandbox.txt`.
  - PowerShell: `guard-e2e-ps.txt` → both PASS. `guard-ps-unset.txt` contains the marker (grep count 1),
    `guard-ps-sandbox.txt` does not (grep count 0).

## 3. Template `plugin/engine/templates/devcontainer.json`
- Strict JSON (no comments): `containerEnv.HARNESS_SANDBOX="1"`, secrets via `remoteEnv`+`${localEnv:...}`,
  volume workspace (`source=harness-workspace,target=/workspace,type=volume`, no host FS bind),
  `postCreateCommand` chmods `specs/` read-only, ubuntu base + github-cli + node features.
- **Proof:** template-validity test parses it with jq (bash) / ConvertFrom-Json (PS) and asserts
  `containerEnv.HARNESS_SANDBOX==1` and the volume workspaceMount. See both run-tests outputs
  ("sandbox template" / "devcontainer" oks).

## 4. Doc `docs/sandboxing.md`
- Covers WHY (deny-list ≠ sandbox; skip-permissions voids it; no native Windows sandbox), HOW DETECTION
  WORKS (HARNESS_SANDBOX contract table + marker list; bare WSL2 not auto-detected), PROFILE A
  (devcontainer, security properties), PROFILE B (raw WSL2, weaker), and THE WARNING text users see.

## 5. Tests
- Added to `harness/tests/run-tests.sh` and `run-tests.ps1`: predicate cases (env-driven, save/restore,
  subshell in bash / finally in PS) + template-validity (jq-gated in bash).

## Gate results (all four suites) — final, after review fixes
| Suite | Baseline | Now | File |
|-------|----------|-----|------|
| run-tests.ps1 | 112 / 0 | **125 / 0** | `run-tests-ps.txt` |
| run-tests.sh  | 103 / 0 | **116 / 0** | `run-tests-bash.txt` |
| fleet-queue-test.ps1 | 22 / 0 | **22 / 0** | `fleet-queue-ps.txt` |
| fleet-queue-test.sh  | 22 / 0 | **22 / 0** | `fleet-queue-bash.txt` |

No existing test weakened. bash suites run with jq prepended to PATH per the plan.
(+2 tests per runner vs the pre-review count of 123/114: the presence-semantics cases added in round 1.)

## Fresh-context REVIEW (codex read-only via Invoke-Phase, `Ok=True Path=codex UsedFallback=False`)
Three rounds — the shipped review primary (`models.review = codex`) dogfooded end-to-end:
1. **REJECT** — auto-detect markers mixed truthy (`CODESPACES`) vs non-empty (`REMOTE_CONTAINERS`/…),
   inconsistent with "any present ⇒ sandboxed"; doc echoed the drift. Log: `review.log`.
   → Fixed: uniform **presence/set-ness** for all four marker env vars (bash `${VAR+x}`, PS `$null -ne
   GetEnvironmentVariable`); doc reworded; +2 presence tests per runner (`CODESPACES=false`→sandboxed,
   `container=lxc`→sandboxed) locking "present, not truthy".
2. **REJECT** — three findings: (a) PS `.Trim()` broke bash parity for `" true "`; (b) `chmod -R a-w specs`
   oversold as the specs/ read-only guarantee; (c) the "unset + no markers" test could FAIL inside a
   container (`/.dockerenv`/cgroup can't be unset). Log: `review-2.log`.
   → Fixed: removed PS `.Trim()`; doc now names the `HARNESS_LOCK_SPECS` protect-specs hook as the
   authoritative guard and chmod as best-effort; both suites' "unset" test branches on host bareness
   (bare→NOT sandboxed, container→sandboxed) so it passes inside the sandbox profile it ships.
3. **SHIP** — no findings. Log: `review-3.log`. This run also e2e-proves the codex review path works.
