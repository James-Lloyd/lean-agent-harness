#!/usr/bin/env bash
# codex-setup.sh - generate the OpenAI Codex CLI surfaces for a harness project (bash twin of
# codex-setup.ps1). Design-doc 002 D3: Codex reads `.codex/` in the repo, so the harness's guard
# hooks, phase agents and skills have to exist there in Codex's own formats - but the plugin lives in
# the per-machine cache, so the generated files carry ABSOLUTE local paths and must never be committed
# (ratchet 2026-07-30). Everything here is therefore GENERATED + GITIGNORED and re-runnable.
#
# Writes, under <project>/.codex/ :
#   config.toml        [features] hooks=true; [[skills.config]] path=<plugin>/skills + enabled=true (NO
#                      [agents] block: in Codex 0.144.3 that table holds agent roles, and unknown keys
#                      under it are a FATAL config-load error - verified live in slice V5)
#   hooks.json         four of the five guard hooks through <plugin>/hooks/run.mjs (lock-config's
#                      ConfigChange has no Codex event). protect-specs / format-and-check / session-start
#                      run under matcher "*" (their bodies exit 0 on a payload without a file path).
#                      block-destructive does NOT: when tool_input.command is absent it scans the WHOLE
#                      payload ("fail toward scanning"), so under "*" a Codex EDIT whose patch text mentions
#                      `rm -rf` would be falsely denied. It is emitted under --shell-matcher (default
#                      "Bash": the tool_name Codex 0.144.3 sends for shell commands, recorded live in
#                      slice V5) - see docs/codex-setup.md.
#   agents/<name>.toml one per plugin agent: model/effort from the phase's effective codex settings,
#                      sandbox_mode read-only for judges, developer_instructions = the agent body
#   .harness-stamp.json plugin version + sha256 of the inputs, so `--check` can detect staleness
# and appends `.codex/` to <project>/.gitignore if missing.
#
# Usage: codex-setup.sh --project-root <repo> [--check] [--user] [--shell-matcher <regex>]
#   --check  exit 0 if the generated set exists and matches the current inputs, 1 if missing/stale
#   --user   ALSO write hooks.json to ~/.codex/hooks.json (override dir with $HARNESS_CODEX_HOME) - the
#            only place repo hooks run under headless `codex exec` without --dangerously-bypass-hook-trust.
#            MACHINE-WIDE: applies to every Codex project on this machine. Refuses to overwrite a
#            hooks.json there that the harness did not generate.
#   --shell-matcher <regex>  the PreToolUse matcher for block-destructive (Codex shell tool name(s)).
#            Default "Bash" was recorded from a real payload in V5; a wrong name means the hook never
#            fires (fail-open for that one hook, never a false denial). Re-record on a Codex upgrade.
set -euo pipefail
# A caller on Windows (the PS test suite, a scheduled task) may invoke this with a backslash path; dirname
# then sees no "/" and yields "." - normalise before resolving our own directory.
_self="${BASH_SOURCE[0]//\\//}"
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PLUGIN_ROOT/hooks"; SKILLS_DIR="$PLUGIN_ROOT/skills"; AGENTS_DIR="$PLUGIN_ROOT/agents"
# Pinned in slice V5 from a recorded Codex 0.144.3 PreToolUse payload: shell commands arrive as
# tool_name "Bash" with tool_input.command (Codex mirrors Claude Code's hook contract; the docs also
# name "Edit"/"Write" for apply_patch edits). Was a best-guess list before V5.
DEFAULT_SHELL_MATCHER="Bash"

PROJECT_ROOT=""; CHECK=0; USER_HOOKS=0; SHELL_MATCHER="$DEFAULT_SHELL_MATCHER"
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2;;
    --project-root=*) PROJECT_ROOT="${1#*=}"; shift;;
    --check) CHECK=1; shift;;
    --user)  USER_HOOKS=1; shift;;
    --shell-matcher) SHELL_MATCHER="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(pwd)"
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
CONFIG="$PROJECT_ROOT/harness/harness.config.json"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG. Run /harness-init first." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required (brew/apt install jq)." >&2; exit 1; }
# shellcheck source=lib/gate.sh
source "$SCRIPT_DIR/lib/gate.sh"   # phase_codex_model / phase_codex_effort

OUT="$PROJECT_ROOT/.codex"
PLUGIN_VERSION="$(jq -r '.version // "unknown"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)"

# --- helpers -------------------------------------------------------------------------------------
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
# TOML/JSON-safe absolute path: native form with forward slashes. Under Git Bash / MSYS `pwd` yields
# /c/Users/... which Codex (a native Windows binary) cannot resolve - cygpath -m gives C:/Users/....
fwd() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1" | sed 's#\\#/#g'; fi; }
toml_basic() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }   # escape for a TOML basic "string"
json_str() { jq -Rn --arg s "$1" '$s'; }                            # JSON-quote a string

# Inputs hash: everything the output is a pure function of. A change to any of these => stale.
# RAW bytes + ordinal file order, so the .ps1 twin computes the identical digest (either twin may
# generate, either may --check) - no JSON re-serialisation, which the two runtimes do differently.
inputs_hash() {
  {
    printf 'plugin=%s\nroot=%s\n' "$PLUGIN_VERSION" "$(fwd "$PLUGIN_ROOT")"
    cat "$CONFIG"
    cat "$HOOKS_DIR/hooks.json"
    # quoting-safe (a plugin cache under a username with a space is common on Windows); ordinal order
    while IFS= read -r f; do printf '## %s\n' "$(basename "$f")"; cat "$f"; done < <(printf '%s\n' "$AGENTS_DIR"/*.md | LC_ALL=C sort)
  } | sha256
}

# --- --check ---------------------------------------------------------------------------------------
if [ "$CHECK" = "1" ]; then
  stamp="$OUT/.harness-stamp.json"
  if [ ! -f "$stamp" ] || [ ! -f "$OUT/config.toml" ] || [ ! -f "$OUT/hooks.json" ] || [ ! -d "$OUT/agents" ]; then
    echo "codex-setup: NOT generated (run harness/codex-setup.sh)"; exit 1
  fi
  want="$(inputs_hash)"; have="$(jq -r '.inputsHash // ""' "$stamp")"
  if [ "$want" != "$have" ]; then echo "codex-setup: STALE (inputs changed since generation; re-run harness/codex-setup.sh)"; exit 1; fi
  echo "codex-setup: fresh (plugin $(jq -r '.pluginVersion' "$stamp"))"; exit 0
fi

# --- generate --------------------------------------------------------------------------------------
mkdir -p "$OUT/agents"
gen_note="GENERATED by lean-agent-harness codex-setup (plugin $PLUGIN_VERSION). Do not edit; re-run harness/codex-setup.* - see docs/codex-setup.md"

# config.toml
# Emit ONLY keys the installed Codex CLI is known to load (verified live against 0.144.3, slice V5): a
# `[[skills.config]]` entry REQUIRES `enabled` (missing => "Error loading config.toml: missing field
# `enabled`", fatal, and the whole .codex/ layer is dead), and `[agents]` is a table of agent ROLES there -
# `enabled = true` / `default_subagent_*` under it are parsed as a role and rejected ("expected struct
# AgentRoleToml"). The per-agent model/effort already lives in agents/<name>.toml, so no global block.
printf '# %s\n\n[features]\nhooks = true\n\n[[skills.config]]\npath = "%s"\nenabled = true\n' "$gen_note" "$(toml_basic "$(fwd "$SKILLS_DIR")")" > "$OUT/config.toml"

# hooks.json - mirror of plugin/hooks/hooks.json with absolute commands; ConfigChange has no Codex event.
# block-destructive is scoped to the shell tool matcher (see header): under "*" its whole-payload
# fallback scan would deny edits whose text merely mentions a denylisted command.
runmjs="$(fwd "$HOOKS_DIR/run.mjs")"
# --codex: Codex ignores a hook's exit code 2 (logged "Failed", call proceeds - fail-open, observed live in
# V5); the dispatcher's codex mode translates exit 2 + stderr into the JSON permissionDecision Codex blocks on.
hook_cmd() { printf 'node "%s" --codex %s' "$runmjs" "$1"; }
jq -n --arg note "$gen_note" --arg sm "$SHELL_MATCHER" \
      --arg bd "$(hook_cmd block-destructive)" --arg ps "$(hook_cmd protect-specs)" \
      --arg fc "$(hook_cmd format-and-check)" --arg ss "$(hook_cmd session-start)" '
  { "_generated_by": $note,
    "_shell_matcher_note": "block-destructive fires only for tools matching this regex; default Bash = the tool_name Codex 0.144.3 sends for shell commands (recorded live in slice V5, docs/codex-setup.md)",
    "hooks": {
      "PreToolUse":  [ { "matcher": $sm,  "hooks": [ { "type": "command", "command": $bd, "timeout": 30 } ] },
                       { "matcher": "*",  "hooks": [ { "type": "command", "command": $ps, "timeout": 30 } ] } ],
      "PostToolUse": [ { "matcher": "*",  "hooks": [ { "type": "command", "command": $fc, "timeout": 120 } ] } ],
      "SessionStart":[ { "matcher": "*",  "hooks": [ { "type": "command", "command": $ss, "timeout": 30 } ] } ]
    } }' > "$OUT/hooks.json"

# agents/*.toml - one per plugin agent. Phase mapping + sandbox mirror the harness's doer/judge split.
agent_phase() { case "$1" in planner) echo plan;; generator) echo implement;; reviewer|risk-classifier) echo review;; evaluator) echo evaluate;; explorer) echo explore;; doc-gardener) echo docs;; *) echo "";; esac; }
agent_sandbox() { case "$1" in reviewer|risk-classifier|evaluator|explorer) echo read-only;; *) echo workspace-write;; esac; }
for f in "$AGENTS_DIR"/*.md; do
  name="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)"
  desc="$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)"
  phase="$(agent_phase "$name")"
  model=""; effort=""
  if [ -n "$phase" ]; then model="$(phase_codex_model "$CONFIG" "$phase")"; effort="$(phase_codex_effort "$CONFIG" "$phase")"; fi
  # body = everything after the closing frontmatter fence; TOML literal ''' string, so it must not contain '''
  body="$(awk 'BEGIN{n=0;started=0} /^---[[:space:]]*$/{n++; if(n<=2) next} n>=2{ if(!started && $0 ~ /^[[:space:]]*$/) next; started=1; print }' "$f")"
  case "$body" in *"'''"*) echo "agent $name body contains ''' - cannot embed as a TOML literal string" >&2; exit 1;; esac
  {
    printf '# %s\nname = "%s"\ndescription = "%s"\n' "$gen_note" "$(toml_basic "$name")" "$(toml_basic "$desc")"
    [ -n "$model" ]  && printf 'model = "%s"\n' "$(toml_basic "$model")"
    [ -n "$effort" ] && printf 'model_reasoning_effort = "%s"\n' "$(toml_basic "$effort")"
    printf 'sandbox_mode = "%s"\ndeveloper_instructions = %s\n%s\n\n%s\n%s\n' "$(agent_sandbox "$name")" "'''" \
      "Running under OpenAI Codex CLI: Claude-Code-specific references below (the Agent tool, slash commands, model: frontmatter and its drift checks) do not apply; the role, rules and output contract do." \
      "$body" "'''"
  } > "$OUT/agents/$name.toml"
done

# stamp
jq -n --arg v "$PLUGIN_VERSION" --arg h "$(inputs_hash)" --arg r "$(fwd "$PLUGIN_ROOT")" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ pluginVersion: $v, inputsHash: $h, pluginRoot: $r, generatedAt: $t }' > "$OUT/.harness-stamp.json"

# .gitignore - the generated set carries machine-local absolute paths: never commit it.
gi="$PROJECT_ROOT/.gitignore"
if ! { [ -f "$gi" ] && tr -d '\r' < "$gi" | grep -qx '\.codex/'; }; then   # CR-strip: a consumer .gitignore may be CRLF
  printf '\n# OpenAI Codex CLI surfaces generated by harness/codex-setup.* (machine-local absolute paths):\n.codex/\n' >> "$gi"
fi

# --user: hooks into ~/.codex/hooks.json (only place repo hooks run under headless `codex exec` untrusted)
if [ "$USER_HOOKS" = "1" ]; then
  home="${HARNESS_CODEX_HOME:-$HOME/.codex}"; mkdir -p "$home"
  if [ -f "$home/hooks.json" ] && ! jq -e '._generated_by' "$home/hooks.json" >/dev/null 2>&1; then
    echo "refusing to overwrite $home/hooks.json: not generated by the harness (merge it by hand)" >&2; exit 1
  fi
  cp "$OUT/hooks.json" "$home/hooks.json"; echo "wrote $home/hooks.json"
fi

n_agents="$(ls "$OUT/agents"/*.toml | wc -l | tr -d ' ')"
echo "codex-setup: wrote $OUT (config.toml, hooks.json, $n_agents agents) for plugin $PLUGIN_VERSION"
echo "NOTE: under headless 'codex exec' the repo's .codex/hooks.json is skipped until the repo is trusted (or --user / --dangerously-bypass-hook-trust) - docs/codex-setup.md"
