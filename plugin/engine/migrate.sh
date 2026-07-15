#!/usr/bin/env bash
# Migrate an existing copied-in harness onto the lean-agent-harness plugin without losing project
# customizations (ratcheted denylists, project-authored skills/agents, tuned config) — bash mirror of
# migrate.ps1. Classifies every engine-ish file against the installed plugin (IDENTICAL / DIFFERS /
# PROJECT-ONLY), never deleting a file whose content the plugin does not already provide verbatim.
# Default = report only. --apply removes IDENTICAL files, strips duplicate engine hook wiring from
# settings.json, installs the 4 runner wrappers, and writes harness/MIGRATION-REPORT.md (git-reversible).
#
# Usage: bash engine/migrate.sh [--project-root <dir>] [--apply] [--replace-runners] [--force]
# Requires: bash, git (for the dirty-tree guard), jq (settings.json surgery).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <pluginRoot>/engine
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"                  # <pluginRoot>

ENGINE_HOOK_NAMES=(block-destructive format-and-check lock-config protect-specs session-start)
RUNNER_NAMES=(loop.ps1 loop.sh fleet.ps1 fleet.sh)

# --- args ----------------------------------------------------------------------
APPLY=0; REPLACE_RUNNERS=0; FORCE=0; PROJECT_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2;;
    --project-root=*) PROJECT_ROOT="${1#*=}"; shift;;
    --apply) APPLY=1; shift;;
    --replace-runners) REPLACE_RUNNERS=1; shift;;
    --force) FORCE=1; shift;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# //'; exit 0;;
    *) echo "migrate.sh: unknown argument '$1'" >&2; exit 2;;
  esac
done

# Project root discovery mirrors loop.sh: --project-root wins; else the git top-level; else the CWD.
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(pwd)"
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

if [ "$APPLY" = 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "migrate.sh --apply needs jq for settings.json surgery (brew/apt install jq)." >&2; exit 1; }
fi

# --- helpers -------------------------------------------------------------------
norm() { sed '1s/^\xEF\xBB\xBF//' "$1" | tr -d '\r'; }   # strip a leading UTF-8 BOM + CRLF

identical() {  # $1 repo, $2 plugin -> exit 0 if byte-identical (normalized)
  [ -f "$1" ] && [ -f "$2" ] || return 1
  diff -q <(norm "$1") <(norm "$2") >/dev/null 2>&1
}

engine_hook_ref() {  # $1 command -> echoes the engine-hook basename it references, else nothing
  # Both boundaries anchored so a project hook like my-block-destructive.sh / pre-session-start.sh is
  # NOT matched as the engine hook it embeds (else its wiring would be stripped silently).
  local cmd="$1" b
  for b in "${ENGINE_HOOK_NAMES[@]}"; do
    if printf '%s' "$cmd" | grep -Eq "(^|[^A-Za-z0-9_.-])${b}\.(ps1|sh)([^A-Za-z0-9_.-]|\$)"; then echo "$b"; return 0; fi
    if printf '%s' "$cmd" | grep -Eq "run\.mjs[\"']?[[:space:]]+${b}([^A-Za-z0-9_.-]|\$)"; then echo "$b"; return 0; fi
  done
  return 0
}

# --- build the classification --------------------------------------------------
# Each ITEMS entry: "CLASS<TAB>display<TAB>repoPath<TAB>pluginPath".
ITEMS=()
DIFFERS_HOOKS=()   # basenames of .claude/hooks/* files classified DIFFERS (for the warn)

add_item() {  # $1 repoPath, $2 pluginPath
  local repo="$1" plugin="$2" class display
  if [ ! -e "$plugin" ]; then class="PROJECT-ONLY"
  elif identical "$repo" "$plugin"; then class="IDENTICAL"
  else class="DIFFERS"; fi
  display="${repo#"$PROJECT_ROOT"/}"
  ITEMS+=("$class"$'\t'"$display"$'\t'"$repo"$'\t'"$plugin")
  if [ "$class" = "DIFFERS" ] && printf '%s' "$display" | grep -Eq '(^|/)\.claude/hooks/'; then
    local base; base="$(basename "$repo")"; base="${base%.*}"
    DIFFERS_HOOKS+=("$base")
  fi
}

classify_dir() {  # $1 repo_dir, $2 plugin_dir, [ext...] (empty = all files)
  local repo_dir="$1" plugin_dir="$2"; shift 2
  [ -d "$repo_dir" ] || return 0
  local f rel ext e ok
  while IFS= read -r -d '' f; do
    if [ "$#" -gt 0 ]; then
      ext="${f##*.}"; ok=0
      for e in "$@"; do [ "$ext" = "$e" ] && ok=1; done
      [ "$ok" = 1 ] || continue
    fi
    rel="${f#"$repo_dir"/}"
    add_item "$f" "$plugin_dir/$rel"
  done < <(find "$repo_dir" -type f -print0)
}

classify_dir "$PROJECT_ROOT/.claude/agents"    "$PLUGIN_ROOT/agents"           md
classify_dir "$PROJECT_ROOT/.claude/commands"  "$PLUGIN_ROOT/commands"         md
classify_dir "$PROJECT_ROOT/.claude/skills"    "$PLUGIN_ROOT/skills"
classify_dir "$PROJECT_ROOT/.claude/hooks"     "$PLUGIN_ROOT/hooks"            ps1 sh
classify_dir "$PROJECT_ROOT/harness/lib"       "$PLUGIN_ROOT/engine/lib"
classify_dir "$PROJECT_ROOT/harness/profiles"  "$PLUGIN_ROOT/engine/profiles"
classify_dir "$PROJECT_ROOT/harness/templates" "$PLUGIN_ROOT/engine/templates"
[ -f "$PROJECT_ROOT/harness/harness.schema.json" ] && \
  add_item "$PROJECT_ROOT/harness/harness.schema.json" "$PLUGIN_ROOT/engine/harness.schema.json"

# Runners (special-case). Each RUNNERS entry: "name<TAB>replace<TAB>reason".
RUNNERS=()
for rn in "${RUNNER_NAMES[@]}"; do
  repo="$PROJECT_ROOT/harness/$rn"
  [ -f "$repo" ] || continue
  engine="$SCRIPT_DIR/$rn"
  if identical "$repo" "$engine"; then replace=1; reason="identical to engine -> thin wrapper (auto)"
  elif [ "$REPLACE_RUNNERS" = 1 ]; then replace=1; reason="differs -> thin wrapper (--replace-runners)"
  else replace=0; reason="differs -> KEPT (pass --replace-runners to swap for a wrapper)"; fi
  RUNNERS+=("$rn"$'\t'"$replace"$'\t'"$reason")
done

# --- print the classification report (always) ----------------------------------
count_class() { local c="$1" n=0 e; for e in "${ITEMS[@]:-}"; do [ -n "$e" ] && [ "${e%%$'\t'*}" = "$c" ] && n=$((n+1)); done; echo "$n"; }

echo ""
echo "harness-migrate — plugin: $PLUGIN_ROOT"
echo "                  project: $PROJECT_ROOT"
echo ""
echo "IDENTICAL to plugin (safe to remove) — $(count_class IDENTICAL) file(s):"
for e in "${ITEMS[@]:-}"; do [ -n "$e" ] || continue
  IFS=$'\t' read -r class display repo plugin <<<"$e"
  [ "$class" = "IDENTICAL" ] && echo "  - $display"; done
echo ""
echo "DIFFERS (KEPT for review — your ratchet, or a newer plugin version) — $(count_class DIFFERS) file(s):"
for e in "${ITEMS[@]:-}"; do [ -n "$e" ] || continue
  IFS=$'\t' read -r class display repo plugin <<<"$e"
  if [ "$class" = "DIFFERS" ]; then
    echo "  ~ $display"
    { diff <(norm "$plugin") <(norm "$repo") 2>/dev/null | head -n 12 | sed 's/^/      /'; } || true
  fi; done
echo ""
echo "PROJECT-ONLY (KEPT — yours) — $(count_class PROJECT-ONLY) file(s):"
for e in "${ITEMS[@]:-}"; do [ -n "$e" ] || continue
  IFS=$'\t' read -r class display repo plugin <<<"$e"
  [ "$class" = "PROJECT-ONLY" ] && echo "  + $display"; done
echo ""
echo "Runners (harness/loop.*, harness/fleet.*):"
for e in "${RUNNERS[@]:-}"; do [ -n "$e" ] || continue
  IFS=$'\t' read -r name replace reason <<<"$e"; echo "  * $name: $reason"; done
echo ""

if [ "$APPLY" != 1 ]; then
  echo "Report only — nothing was written. Re-run with --apply to perform the migration."
  echo "(--apply removes IDENTICAL files, strips duplicate hook wiring, installs runner wrappers,"
  echo " and writes harness/MIGRATION-REPORT.md — all reversible via git.)"
  exit 0
fi

# --- APPLY ---------------------------------------------------------------------
# 1. Guard the tree. A non-git target has no `git checkout` undo (only runner .bak backups), so refuse
#    unless --force; a git target must be clean so the migration lands as one reviewable diff.
IS_GIT=0
git -C "$PROJECT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 && IS_GIT=1
if [ "$FORCE" != 1 ]; then
  if [ "$IS_GIT" != 1 ]; then
    echo "Target is not a git repository, so --apply deletions would NOT be reversible. Pass --force to proceed anyway (only runner .pre-plugin.bak backups are kept)." >&2
    exit 1
  fi
  if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "Working tree is not clean. Commit or stash first so the migration is a single reviewable diff, or pass --force." >&2
    exit 1
  fi
fi

# 2. Remove IDENTICAL engine files + prune emptied dirs. Step 3 decides which settings wiring to strip
#    by whether the referenced hook FILE is still on disk after this removal (not by basename).
REMOVED=()
for e in "${ITEMS[@]:-}"; do [ -n "$e" ] || continue
  IFS=$'\t' read -r class display repo plugin <<<"$e"
  if [ "$class" = "IDENTICAL" ]; then rm -f "$repo"; REMOVED+=("$display"); fi
done
for pr in .claude/agents .claude/commands .claude/skills .claude/hooks harness/lib harness/profiles harness/templates; do
  d="$PROJECT_ROOT/$pr"
  [ -d "$d" ] && { find "$d" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true; }
done

# 3. Strip engine hook wiring from .claude/settings.json — ONLY for hooks whose FILE we removed
#    (IDENTICAL). A DIFFERS-kept hook KEEPS its wiring so its ratcheted rule keeps firing (harmlessly
#    redundant with the plugin's stock hook for a denylist); silently un-wiring a customized guardrail
#    and only warning would disable it during the exact window an autonomous loop is running.
SETTINGS_EDITS=()
WARNINGS=()
settings="$PROJECT_ROOT/.claude/settings.json"
if [ -f "$settings" ]; then
  # Split wired engine hooks into strip (referenced FILE now absent) vs keep (file still on disk).
  STRIP_FILES=()   # exact hook filenames (name.ext) whose wiring to strip
  KEPT_WIRED=()    # engine-hook basenames whose wiring we keep
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    ref="$(engine_hook_ref "$cmd")"
    [ -n "$ref" ] || continue
    reffile="$(printf '%s' "$cmd" | grep -Eo "${ref}\.(ps1|sh)" | head -1)"
    if [ -n "$reffile" ] && [ ! -e "$PROJECT_ROOT/.claude/hooks/$reffile" ]; then
      STRIP_FILES+=("$reffile")
    else
      KEPT_WIRED+=("$ref")
    fi
  done < <(jq -r '(.hooks // {}) | .[]? | .[]? | (.hooks // [])[]? | (.command // "")' "$settings" 2>/dev/null || true)
  # Dedupe without bash-4 mapfile (macOS ships bash 3.2 — the .sh mirror's primary target).
  dedupe() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++'; }
  STRIP_U=(); while IFS= read -r x; do [ -n "$x" ] && STRIP_U+=("$x"); done < <(dedupe "${STRIP_FILES[@]:-}")
  KEPT_U=();  while IFS= read -r x; do [ -n "$x" ] && KEPT_U+=("$x"); done < <(dedupe "${KEPT_WIRED[@]:-}")
  if [ "${#STRIP_U[@]}" -gt 0 ]; then
    # Regex of the EXACT filenames to strip (dots escaped), both boundaries anchored — so a kept .ps1
    # is untouched when its sibling .sh was removed, and my-block-destructive.sh is never matched.
    ESC=(); for f in "${STRIP_U[@]}"; do ESC+=("$(printf '%s' "$f" | sed 's/\./\\./g')"); done
    NAMES="$(printf '%s|' "${ESC[@]}")"; NAMES="${NAMES%|}"
    RE="(^|[^A-Za-z0-9_.-])(${NAMES})([^A-Za-z0-9_.-]|\$)"
    tmp="$(mktemp)"
    jq --arg re "$RE" '
      if (has("hooks") and (.hooks != null)) then
        .hooks |= (
          with_entries(
            .value |= (
              map( if has("hooks") then (.hooks |= map(select((.command // "") | test($re) | not))) else . end )
              | map(select((has("hooks") | not) or ((.hooks | length) > 0)))
            )
          )
          | with_entries(select((.value | length) > 0))
        )
        | (if (.hooks | length) == 0 then del(.hooks) else . end)
      else . end
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    for f in "${STRIP_U[@]}"; do SETTINGS_EDITS+=("stripped engine hook wiring (file removed): $f"); done
  fi
  # For a DIFFERS-kept hook we deliberately KEEP the wiring so the ratchet keeps firing; tell the human
  # it now runs alongside the plugin's stock hook (harmless for a denylist) and should be ported + de-duped.
  for s in "${KEPT_U[@]:-}"; do
    [ -n "$s" ] || continue
    for dh in "${DIFFERS_HOOKS[@]:-}"; do
      if [ "$s" = "$dh" ]; then
        WARNINGS+=("KEPT the wiring for your customized .claude/hooks/$s.* so it keeps firing — it now runs alongside the plugin's stock $s. Port your change into the plugin, then remove the local copy + its wiring when ready.")
      fi
    done
  done
fi

# 4. Install runner wrappers (special-case).
WRAPPERS_INSTALLED=()
RUNNERS_KEPT=()
for e in "${RUNNERS[@]:-}"; do [ -n "$e" ] || continue
  IFS=$'\t' read -r name replace reason <<<"$e"
  repo="$PROJECT_ROOT/harness/$name"
  wrapper="$SCRIPT_DIR/wrappers/$name"
  if [ "$replace" = 1 ] && [ -f "$wrapper" ]; then
    cp -f "$repo" "$repo.pre-plugin.bak"
    cp -f "$wrapper" "$repo"
    WRAPPERS_INSTALLED+=("$name")
  else
    RUNNERS_KEPT+=("$name — $reason")
  fi
done

# 5. Write MIGRATION-REPORT.md and print a summary.
report="$PROJECT_ROOT/harness/MIGRATION-REPORT.md"
{
  echo "# Harness migration report"
  echo ""
  echo "Plugin: \`$PLUGIN_ROOT\`  "
  echo "Project: \`$PROJECT_ROOT\`  "
  if [ "$IS_GIT" = 1 ]; then
    echo "Generated by \`migrate.sh --apply\` — all changes are reversible via \`git\`."
  else
    echo "Generated by \`migrate.sh --apply --force\` on a NON-git target — deletions are NOT reversible (only \`.pre-plugin.bak\` runner backups exist)."
  fi
  echo ""
  echo "## Removed (IDENTICAL to the plugin — ${#REMOVED[@]})"
  if [ "${#REMOVED[@]}" -eq 0 ]; then echo "_none_"; else for x in "${REMOVED[@]}"; do echo "- \`$x\`"; done; fi
  echo ""
  echo "## Kept — DIFFERS (review: your ratchet, or a newer plugin version — $(count_class DIFFERS))"
  n=0; for e in "${ITEMS[@]:-}"; do [ -n "$e" ] || continue; IFS=$'\t' read -r class display repo plugin <<<"$e"; [ "$class" = "DIFFERS" ] && { echo "- \`$display\`"; n=$((n+1)); }; done; [ "$n" -eq 0 ] && echo "_none_"
  echo ""
  echo "## Kept — PROJECT-ONLY (yours — $(count_class PROJECT-ONLY))"
  n=0; for e in "${ITEMS[@]:-}"; do [ -n "$e" ] || continue; IFS=$'\t' read -r class display repo plugin <<<"$e"; [ "$class" = "PROJECT-ONLY" ] && { echo "- \`$display\`"; n=$((n+1)); }; done; [ "$n" -eq 0 ] && echo "_none_"
  echo ""
  echo "## settings.json edits"
  if [ "${#SETTINGS_EDITS[@]}" -eq 0 ]; then echo "_none_"; else for x in "${SETTINGS_EDITS[@]}"; do echo "- $x"; done; fi
  echo ""
  echo "## Runner wrappers installed"
  if [ "${#WRAPPERS_INSTALLED[@]}" -eq 0 ]; then echo "_none_"; else for x in "${WRAPPERS_INSTALLED[@]}"; do echo "- \`harness/$x\` (original backed up to \`harness/$x.pre-plugin.bak\`)"; done; fi
  if [ "${#RUNNERS_KEPT[@]}" -gt 0 ]; then
    echo ""
    echo "Runners kept (not swapped):"
    for x in "${RUNNERS_KEPT[@]}"; do echo "- $x"; done
  fi
  echo ""
  echo "## Manual next-steps"
  for w in "${WARNINGS[@]:-}"; do [ -n "$w" ] && echo "- WARN: $w"; done
  echo "- Review every **DIFFERS** file: port a genuine customization (e.g. a ratcheted denylist) into the plugin or a project hook, then remove the local copy; if it is merely an older plugin version, delete the local copy."
  echo "- Confirm the \`.pre-plugin.bak\` runner backups can be deleted once the wrappers are verified."
  echo "- Review \`git diff\` and commit."
} > "$report"

echo "Applied migration:"
echo "  removed ${#REMOVED[@]} IDENTICAL file(s); kept $(count_class DIFFERS) DIFFERS + $(count_class PROJECT-ONLY) PROJECT-ONLY"
echo "  settings.json: ${#SETTINGS_EDITS[@]} edit(s)"
if [ "${#WRAPPERS_INSTALLED[@]}" -gt 0 ]; then echo "  wrappers installed: ${WRAPPERS_INSTALLED[*]}"; else echo "  wrappers installed: none"; fi
for w in "${WARNINGS[@]:-}"; do [ -n "$w" ] && echo "  WARN: $w"; done
echo "  report: harness/MIGRATION-REPORT.md"
echo ""
echo "Review 'git diff', then commit."
exit 0
