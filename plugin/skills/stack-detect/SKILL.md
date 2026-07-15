---
name: stack-detect
description: Detect a project's tech stack and derive the verification gate. Use during /harness-init, or whenever the build/test/lint commands are unknown and need to be established for the harness config.
---

# stack-detect

Determine what stack(s) a repo uses and translate that into the harness's per-component verification
gates. The harness core is stack-agnostic; this skill is the bridge that fills
`harness/harness.config.json` → `components[]` (+ the cross-cutting `gate`) and the run/build/test
commands in `CLAUDE.md` / `AGENT_NOTES.md`.

## 0. First: is this one component or several?
Many projects are **headless** — one root folder containing multiple sub-repos, each with its own root
files (e.g. `frontend/` with `package.json` + `backend/` with `pyproject.toml`). Detect this **before**
detecting stacks:
- Look for manifests/lockfiles in **immediate subdirectories**, not just the root (`*/package.json`,
  `*/pyproject.toml`, `*/go.mod`, `*/Cargo.toml`, `*/pom.xml`, etc.).
- Also recognize in-tool monorepos (workspaces in a root `package.json`, `pnpm-workspace.yaml`,
  `turbo.json`, Nx, Cargo workspaces, Go modules).
- **One manifest at root** → a single component with `path: "."`.
  **Manifests in subdirs** → one component per sub-repo (e.g. `frontend`, `backend`), each with its own
  path, stack, and gate. Confirm the split and the directory names with the human.
- Cross-cutting integration/e2e that spans components (a Playwright suite hitting the running FE+BE,
  a docker-compose smoke test) belongs in the **top-level `gate`**, not in any single component.

Run the per-stack detection below **once per component**, in that component's directory.

## 1. Gather signals (don't ask what you can detect)
Glob/read for manifests and lockfiles, then confirm with the human only the ambiguous parts.

| Signal file(s) | Stack | Typical gate (confirm, don't assume) |
|---|---|---|
| `package.json` + `tsconfig.json` | TypeScript/Node | prettier · eslint · `tsc --noEmit` · build · vitest/jest · playwright |
| `package.json` only | JavaScript/Node | prettier · eslint · (no typecheck) · build · jest |
| `pyproject.toml` / `requirements.txt` | Python | ruff format · ruff check · pyright/mypy · — · pytest |
| `go.mod` | Go | gofmt · golangci-lint · `go vet` · `go build` · `go test` |
| `Cargo.toml` | Rust | `cargo fmt` · `cargo clippy` · (compiler types) · `cargo build` · `cargo test` |
| `pom.xml` / `build.gradle` | Java/Kotlin | spotless · — · compiler · build · junit |
| `*.csproj` / `*.sln` | .NET | `dotnet format` · analyzers · build · `dotnet test` |
| `Gemfile` | Ruby | rubocop -A · rubocop · — · rspec |
| `composer.json` | PHP | php-cs-fixer · phpstan · — · phpunit |
| `mix.exs` | Elixir | `mix format` · credo · dialyzer · — · `mix test` |
| `Dockerfile` / `compose.yaml` | (containerized) | note how the app actually runs |

Also detect: package manager (lockfile), monorepo (workspaces / multiple manifests → consider nested
`CLAUDE.md` per package), and the OS (for hook wiring).

## 2. Resolve the real commands
Lockfiles tell you the package manager; `package.json` `scripts` (or the Makefile/justfile/taskfile)
tell you the *actual* invocations — prefer those over guessing the canonical command. A step with no
real command is `null` (e.g. an untyped language has no `typecheck`).

For a **brownfield** project, the gate already exists — **discover it, don't invent it**. The CI config
(`.github/workflows/*`, `.gitlab-ci.yml`, etc.) is the real source of truth for "what must pass";
mirror those commands. Then confirm the existing tests are green (the baseline) before any work.

## 3. Pick or create a profile
- If `harness/profiles/<stack>.json` matches, use it (adjust commands to the repo's reality).
- Otherwise copy `harness/profiles/_template.json` to `harness/profiles/<stack>.json`, fill it, and
  reference it from config. Record the LSP server(s) so the agent prefers real diagnostics over guesses.

## 4. Write through
For each component, add an entry to `harness/harness.config.json` → `components[]` with its `path`,
`profile`, `languages`, `packageManager`, `commands`, and merged `gate`. Put any cross-cutting e2e in
the top-level `gate`. Fill the Components table in `CLAUDE.md` and the run/build/test commands in
`AGENT_NOTES.md`. For each non-trivial component, drop a nested `CLAUDE.md` in its directory (copy
`harness/templates/component-CLAUDE.md`). Then **prove each gate command runs** (exit 0 from that
component's directory on a clean tree) before declaring detection complete — a gate that doesn't
execute is worse than none.
