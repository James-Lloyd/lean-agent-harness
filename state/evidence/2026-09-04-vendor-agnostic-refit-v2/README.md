# Evidence — vendor-agnostic refit V2: per-phase Codex model/effort overrides (2026-09-04)

Branch `worktree-feat+vendor-refit-v2-codex-overrides` (stacked on V1, PR #11), plugin 0.3.2,
design-doc `docs/design-docs/002-vendor-agnostic-routing.md` D2.

## User-visible behaviour: a phase's own `codex{model,reasoningEffort}` reaches `codex exec`

Deterministic end-to-end through the real dispatcher, with a stub `codex` binary standing in for the
CLI (the harness never trusts codex exit codes, only the `--output-last-message` text, so the stub
exercises the exact contract the real CLI does):

| case (bash 8x / PS 9x) | config | observed on codex argv | verdict path |
|---|---|---|---|
| 8a/9a | `review = { model: "codex", codex: { model: "gpt-per-phase", reasoningEffort: "xhigh" } }`, global `models.codex.model = "gpt-global"` | stub log `model=gpt-per-phase effort="xhigh"` — the per-phase block, not the global | `INVOKE_PHASE_PATH=codex`, no fallback |
| 8b/9b | same | — | the `--output-last-message` file's `VERDICT: SHIP` is what the dispatcher returned |
| 8c/9c | same | `-m gpt-per-phase` and `-c model_reasoning_effort="xhigh"` present | — |
| 8d (bash) | model/effort empty | stub log `model= effort=` (no `-m`, no `-c`) | float on the CLI default |

Resolver assertions (7 bash / 8 PS): per-phase model wins over global; per-phase effort wins over global;
partial override (model from phase, effort inherited); no phase block ⇒ global; flat-legacy `"codex"`
string ⇒ global; no global + no block ⇒ empty/null (CLI default); PS also: `auth`/`timeoutSeconds` carried
through from the global block only.

## Gate on the final tree

| Suite | Result |
|---|---|
| bash `harness/tests/run-tests.sh` | 256 passed, 0 failed (245 + 7 resolver + 4 stub-codex) |
| PS 5.1 `harness/tests/run-tests.ps1` | 266 passed, 0 failed (255 + 8 resolver + 3 stub-codex) |
| bash `fleet-queue-test.sh` | 31 passed, 0 failed |
| PS 5.1 `fleet-queue-test.ps1` | 31 passed, 0 failed |
| pwsh | not installed on this box — CI job `harness-selftest` covers it |

## Surfaces changed together

Engine: `lib/gate.sh` (`phase_codex_model`, `phase_codex_effort`), `lib/gate.ps1` (`Resolve-PhaseCodexCfg`),
`loop.sh`/`loop.ps1` (three call sites, per-phase), `fleet.sh`/`fleet.ps1` (implement). Contract:
`harness.schema.json` (phaseRouting gains `codex{model,reasoningEffort}`; `models.codex` is now documented
as the global default), `/harness-doctor` check 10(g) (unread-key ⚠️ on non-codex phases; non-codex
effort level or auth/timeout inside a phase block ❌), `model-routing` skill, `/review` command,
comments in `dispatch.sh` and `invoke-codex.ps1`. No shipped config change: the defaults stay
single-vendor Claude, so nothing routes to codex until a consumer edits its config.

## Fresh-context review

Reviewer agent on `claude-fable-5-1`; verdict and applied findings recorded in the commit message.
