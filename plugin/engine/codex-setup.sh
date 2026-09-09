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
# AND, under <project>/.agents/skills/ :
#   <name>/SKILL.md    every harness COMMAND as a Codex skill (`harness-<command>`) plus the plugin's
#                      reference skills. This is the ONLY skill location `codex exec` reads - the
#                      config.toml [[skills.config]] stanza is inert for exec (measured 0.153.4,
#                      state/evidence/2026-09-09-v6.3-command-skill-bridge/). Dirs carrying a
#                      .harness-generated marker are ours to replace; anything else is left alone.
# and appends `.codex/` and `.agents/` to <project>/.gitignore if missing.
#
# Usage: codex-setup.sh --project-root <repo> [--check] [--user] [--shell-matcher <regex>]
#   --check  exit 0 if the generated set exists and matches the current inputs, 1 if missing/stale
#   --user   ALSO write hooks.json to ~/.codex/hooks.json (override dir with $HARNESS_CODEX_HOME) - the
#            ONLY file headless `codex exec` loads hooks from (V5: the project file is never loaded
#            headlessly); it still needs `/hooks` trust once, or --dangerously-bypass-hook-trust per run.
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
CMDS_DIR="$PLUGIN_ROOT/commands"   # source of the command->skill bridge (design-doc 002 V6)
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
# Body after the closing frontmatter fence, leading blank lines dropped AND trailing blank lines
# dropped - the trailing strip mirrors the PS twin's `while ($body[-1].Trim() -eq '') { RemoveAt }`,
# without which a source file ending in a blank line makes the two twins emit different bytes.
strip_frontmatter() {  # $1 file
  awk 'BEGIN{n=0;started=0}
       /^---[[:space:]]*$/{n++; if(n<=2) next}
       n>=2{ if(!started && $0 ~ /^[[:space:]]*$/) next; started=1; buf[++m]=$0 }
       END{ while(m>0 && buf[m] ~ /^[[:space:]]*$/) m--; for(i=1;i<=m;i++) print buf[i] }' "$1"
}

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
    # The generated .agents/skills/ set is derived from these, so a change to either must read STALE.
    while IFS= read -r f; do printf '## %s\n' "$(basename "$f")"; cat "$f"; done < <(printf '%s\n' "$CMDS_DIR"/*.md | LC_ALL=C sort)
    # Sort by DIRECTORY NAME, not by the full `<dir>/SKILL.md` path: the PS twin sorts dir names, and
    # the two orders diverge whenever one name is a proper prefix of another and the next character is
    # below '/' (0x2F) -- `foo` vs `foo-bar` sorts foo-bar-first by path and foo-first by name, which
    # would make --check read STALE forever on one twin. Not live today (no prefix pairs), pinned here.
    while IFS= read -r d; do printf '## %s\n' "$d"; cat "$SKILLS_DIR/$d/SKILL.md"; done < <(
      for p in "$SKILLS_DIR"/*/SKILL.md; do [ -f "$p" ] && basename "$(dirname "$p")"; done | LC_ALL=C sort)
  } | sha256
}

# --- --check ---------------------------------------------------------------------------------------
if [ "$CHECK" = "1" ]; then
  stamp="$OUT/.harness-stamp.json"
  if [ ! -f "$stamp" ] || [ ! -f "$OUT/config.toml" ] || [ ! -f "$OUT/hooks.json" ] || [ ! -d "$OUT/agents" ]; then
    echo "codex-setup: NOT generated (run harness/codex-setup.sh)"; exit 1
  fi
  # The .agents/skills/ bridge is part of the generated set and lives OUTSIDE $OUT, so the existence
  # gate above cannot see it: without this, deleting the whole bridge still reported `fresh` (the
  # inputs digest is over the plugin SOURCES, not the outputs) and /harness-doctor 12 - which runs
  # exactly this - gave a green health check on the slice's headline deliverable.
  # `|| true` on BOTH: this file sets `pipefail`, and `find` on a missing dir exits non-zero, so the
  # assignment aborts the whole script under errexit -- which LOOKS like the guard working (exit 1)
  # while printing nothing at all. Measured on the first draft of this block (engine AGENTS.md: "a
  # $(pipeline) assignment under pipefail aborts"). A guard that cannot say why it failed is not a guard.
  want_skills="$(( $(printf '%s\n' "$CMDS_DIR"/*.md | wc -l) + $(printf '%s\n' "$SKILLS_DIR"/*/SKILL.md | wc -l) ))"
  have_skills="$( { find "$PROJECT_ROOT/.agents/skills" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [ "$have_skills" -eq 0 ]; then
    echo "codex-setup: NOT generated (.agents/skills is missing - run harness/codex-setup.sh)"; exit 1
  elif [ "$have_skills" -lt "$want_skills" ]; then
    echo "codex-setup: STALE (.agents/skills has $have_skills of $want_skills skills; re-run harness/codex-setup.sh)"; exit 1
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
# `enabled`", fatal, and the whole .codex/ layer is dead).
# BUT THE STANZA DELIVERS NO SKILLS TO `codex exec` - measured 2026-09-09 on 0.153.4 with a canary
# token present in exactly one file (state/evidence/2026-09-09-v6.3-command-skill-bridge/): the same
# SKILL.md is found under `.agents/skills/` and returns NO-SKILL behind a `[[skills.config]]` path, in
# the same trusted project on the same question, with an in-run witness proving the config file itself
# WAS loaded. Scope: the root-of-skill-dirs form the harness emits, under `codex exec`. It is kept, not deleted, for one honest reason: the
# measurement covers `codex exec` only, and an interactive session may still read it. The skills the
# harness actually relies on are written to `.agents/skills/` further down. Do not cite this stanza as
# the mechanism that gives Codex the harness skills - it is not.
# `[agents]` is a table of agent ROLES -
# `enabled = true` / `default_subagent_*` under it are parsed as a role and rejected ("expected struct
# AgentRoleToml"). The per-agent model/effort already lives in agents/<name>.toml, so no global block.
# THE CODEX SESSION'S OWN MODEL/DEPTH, from models.session.codex{}. `models.session.model` must be a
# Claude model (the Claude Code window cannot swap vendor mid-session, doctor 10(b)) - but a CODEX
# session is a different process with the same need, and top-level `model` / `model_reasoning_effort`
# in this file is how it is set. Measured 2026-09-09: a top-level key here DOES bind (the transcript
# header changed), which is what makes this the session surface rather than a guess.
# TOP-LEVEL, so they must be emitted BEFORE the first table header - in TOML a bare key belongs to the
# table above it, and writing them after `[features]` would silently make them feature flags.
SESSION_CODEX_MODEL="$(phase_codex_model "$CONFIG" session)"
SESSION_CODEX_EFFORT="$(phase_codex_effort "$CONFIG" session)"
{
  printf '# %s\n\n' "$gen_note"
  if [ -n "$SESSION_CODEX_MODEL" ] && [ "$SESSION_CODEX_MODEL" != "null" ]; then
    printf 'model = "%s"\n' "$(toml_basic "$SESSION_CODEX_MODEL")"
  fi
  if [ -n "$SESSION_CODEX_EFFORT" ] && [ "$SESSION_CODEX_EFFORT" != "null" ]; then
    printf 'model_reasoning_effort = "%s"\n' "$(toml_basic "$SESSION_CODEX_EFFORT")"
  fi
  printf '\n[features]\nhooks = true\n\n[[skills.config]]\npath = "%s"\nenabled = true\n' "$(toml_basic "$(fwd "$SKILLS_DIR")")"
} > "$OUT/config.toml"

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

# .agents/skills/ - THE ONLY SKILL LOCATION CODEX EXEC ACTUALLY READS.
# Measured 2026-09-09 on codex-cli 0.153.4 with a canary token that existed in one file and nowhere
# else (state/evidence/2026-09-09-v6.3-command-skill-bridge/): a skill under `.agents/skills/<name>/`
# is discovered and used WITHOUT being named in the prompt, while the identical file behind a
# `[[skills.config]] path` entry is never reached - same repo, same trusted project, same question,
# one found and one NO-SKILL. So the config stanza above has never delivered a skill to `codex exec`.
# Two things this emits:
#   1. the plugin's reference skills, verbatim (they already carry name/description frontmatter);
#   2. the harness's COMMANDS as skills - the command->skill bridge (design-doc 002 slice V6). A Codex
#      operator has no /work or /review; these give the same orchestration prose a name Codex can find.
SKILLS_OUT="$PROJECT_ROOT/.agents/skills"
SKILL_COLLISIONS=0
mkdir -p "$SKILLS_OUT"
# Wipe only what WE generated, so a hand-written skill beside ours survives a re-run.
for d in "$SKILLS_OUT"/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/.harness-generated" ] && { rm -f "$d/.harness-generated" "$d/SKILL.md"; rmdir "$d" 2>/dev/null; }
done
emit_skill() {  # $1 skill-name  $2 description  $3 body-file  $4 preamble(optional)
  local sd="$SKILLS_OUT/$1"
  # A hand-written skill whose name collides with a generated one must not be silently eaten: without
  # this it would be overwritten AND stamped .harness-generated, making it a wipe target for every
  # future run. Skip and warn instead - the operator renames one of the two.
  if [ -f "$sd/SKILL.md" ] && [ ! -f "$sd/.harness-generated" ]; then
    echo "codex-setup: SKIPPING $1 - a hand-written skill of that name already exists (rename it to let the harness generate this one)" >&2
    SKILL_COLLISIONS=$((SKILL_COLLISIONS + 1))
    return 0
  fi
  mkdir -p "$sd"
  { printf -- '---\nname: %s\ndescription: %s\n---\n\n' "$1" "$2"
    printf '<!-- %s -->\n\n' "$gen_note"
    [ -n "${4:-}" ] && printf '%s\n\n' "$4"
    cat "$3"
  } > "$sd/SKILL.md"
  : > "$sd/.harness-generated"
}
# 1. reference skills, unchanged
for sf in "$SKILLS_DIR"/*/SKILL.md; do
  [ -f "$sf" ] || continue
  sname="$(sed -n 's/^name:[[:space:]]*//p' "$sf" | head -1)"
  sdesc="$(sed -n 's/^description:[[:space:]]*//p' "$sf" | head -1)"
  [ -n "$sname" ] || sname="$(basename "$(dirname "$sf")")"
  sbody="$(mktemp)"
  strip_frontmatter "$sf" > "$sbody"
  emit_skill "$sname" "$sdesc" "$sbody"
  rm -f "$sbody"
done
# 2. the bridge: one skill per harness command, prefixed so it cannot collide with the above.
CMD_PREAMBLE="**You are running under the OpenAI Codex CLI, not Claude Code.** This is a harness command translated into a skill. Read \`AGENTS.md\` at the repo root for the project map (Codex reads it natively; Claude Code gets the same content plus a short Claude-specific section through \`CLAUDE.md\`). Translations that apply throughout the text below: a **slash command** (\`/work\`, \`/review\`, and so on) is another skill in this same directory named \`harness-<command>\` - except for a command whose own name already begins \`harness-\`, which keeps it (\`/harness-doctor\` is the skill \`harness-doctor\`, never \`harness-harness-doctor\`); invoke one by reading it, not by typing the slash form, which does not exist here. **\`\$ARGUMENTS\`** is whatever the operator asked for in their own words - substitute it, or take the command's stated default when they gave none. **\`\${CLAUDE_PLUGIN_ROOT}\`** does not expand under Codex; the same engine scripts are reachable through this repo's own \`harness/\` wrappers (\`harness/loop.sh\`, \`harness/codex-setup.sh\`, and so on). A **subagent** named in the text (\`generator\`, \`reviewer\`, \`planner\`, \`explorer\`, \`evaluator\`, \`doc-gardener\`) has a Codex role definition under \`.codex/agents/<name>.toml\` carrying that phase's model, reasoning effort and sandbox; where the text says to spawn one, either delegate to that role or do the work yourself under its rules and its sandbox - and keep the harness's own rule that the doer is never the judge. **\`allowed-tools\` frontmatter, \`model:\` frontmatter and their drift checks are Claude-Code-only and do not apply.** Everything else - the phase order, the gates, the guardrails, the output contract - applies unchanged."
for cf in "$CMDS_DIR"/*.md; do
  [ -f "$cf" ] || continue
  cname="$(basename "$cf" .md)"
  # `harness-doctor.md` etc. already carry the prefix; don't emit `harness-harness-doctor`.
  # The preamble states this exception too - without it, a Codex agent following the preamble
  # literally would look for `harness-harness-doctor`, which is exactly the name this avoids.
  case "$cname" in harness-*) sname_out="$cname";; *) sname_out="harness-$cname";; esac
  cdesc="$(sed -n 's/^description:[[:space:]]*//p' "$cf" | head -1)"
  [ -n "$cdesc" ] || cdesc="The harness's /$cname command, translated for Codex."
  cbody="$(mktemp)"
  strip_frontmatter "$cf" > "$cbody"
  emit_skill "$sname_out" "$cdesc" "$cbody" "$CMD_PREAMBLE"
  rm -f "$cbody"
done
SKILL_COUNT="$(find "$SKILLS_OUT" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"

# stamp
jq -n --arg v "$PLUGIN_VERSION" --arg h "$(inputs_hash)" --arg r "$(fwd "$PLUGIN_ROOT")" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ pluginVersion: $v, inputsHash: $h, pluginRoot: $r, generatedAt: $t }' > "$OUT/.harness-stamp.json"

# .gitignore - the generated set carries machine-local absolute paths: never commit it.
gi="$PROJECT_ROOT/.gitignore"
# CR-strip: a consumer .gitignore may be CRLF. Here-string, never `tr < "$gi" | grep -qx`: this file
# sets `pipefail`, so on a .gitignore past the pipe buffer grep would exit at the match, tr would die
# of SIGPIPE, the pipeline would report 141, and the guard would read "`.codex/` absent" and append it
# AGAIN on every run. Reading the file into the here-string costs nothing at .gitignore sizes.
if ! { [ -f "$gi" ] && grep -qx '\.codex/' <<< "$(tr -d '\r' < "$gi")"; }; then
  printf '\n# OpenAI Codex CLI surfaces generated by harness/codex-setup.* (machine-local absolute paths):\n.codex/\n' >> "$gi"
fi
# .agents/skills/ is generated from the installed plugin too, so it is machine-local for the same
# reason and gets its own line (separate guard: a repo set up before the bridge shipped already has
# the `.codex/` line, so a combined check would never append this one).
if ! { [ -f "$gi" ] && grep -qx '\.agents/' <<< "$(tr -d '\r' < "$gi")"; }; then
  # LEADING NEWLINE UNLESS THE FILE ALREADY ENDS WITH ONE. The `.codex/` block above opens with `\n`,
  # and that newline is NOT inherited by a block appended beside it: on a .gitignore with no trailing
  # newline this wrote `.codex/.agents/`, destroying BOTH patterns and un-ignoring the machine-local
  # `.codex/` dir (ratchet 2026-07-30's exact failure). The trigger is the upgrade path this very
  # block exists for - a pre-bridge repo whose .gitignore was hand-edited.
  if [ -s "$gi" ] && [ -n "$(tail -c 1 "$gi")" ]; then printf '\n' >> "$gi"; fi
  printf '.agents/\n' >> "$gi"
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
echo "codex-setup: wrote $SKILLS_OUT ($SKILL_COUNT skills - the harness commands as harness-<name>, plus the reference skills)"
echo "NOTE: .agents/skills/ is where 'codex exec' actually finds skills; the config.toml [[skills.config]] stanza does NOT deliver them (measured 0.153.4) - docs/codex-setup.md"
echo "NOTE: under headless 'codex exec' the repo's .codex/hooks.json is NEVER loaded (Codex 0.144.3, slice V5) - use --user (~/.codex/hooks.json) plus /hooks trust or --dangerously-bypass-hook-trust; the project file serves interactive sessions - docs/codex-setup.md"
