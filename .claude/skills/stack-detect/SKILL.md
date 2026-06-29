---
name: stack-detect
description: Detect a project's tech stack and derive the verification gate. Use during /harness-init, or whenever the build/test/lint commands are unknown and need to be established for the harness config.
---

# stack-detect

Determine what stack a repo uses and translate that into the harness's verification gate. The harness
core is stack-agnostic; this skill is the bridge that fills `harness/harness.config.json` → `gate` and
the run/build/test commands in `CLAUDE.md` / `AGENT_NOTES.md`.

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

## 3. Pick or create a profile
- If `harness/profiles/<stack>.json` matches, use it (adjust commands to the repo's reality).
- Otherwise copy `harness/profiles/_template.json` to `harness/profiles/<stack>.json`, fill it, and
  reference it from config. Record the LSP server(s) so the agent prefers real diagnostics over guesses.

## 4. Write through
Merge the profile's `gate` into `harness/harness.config.json`, set `stack.*`, and fill the run/build/
test commands in `CLAUDE.md` and `AGENT_NOTES.md`. Then **prove each gate command runs** (exit 0 on a
clean tree) before declaring detection complete — a gate that doesn't execute is worse than none.
