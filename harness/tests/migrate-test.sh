#!/usr/bin/env bash
# migrate-test.sh — end-to-end self-test for engine/migrate.sh (acceptance criterion 2), mirror of
# migrate-test.ps1. Builds a synthetic copied-in harness in a temp dir with one of each class, runs the
# report then --apply, and asserts the ratchet + project skill survive, IDENTICAL files are removed,
# settings.json is surgically stripped, and the runner wrappers land. Exit 0 = pass, 1 = fail.
# The --apply half is jq-dependent (settings surgery) and skipped when jq is absent, like run-tests.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLUGIN="$REPO/plugin"
ENGINE="$PLUGIN/engine"
MIGRATE="$ENGINE/migrate.sh"

PASS=0; FAIL=0
ok() { if [ "$1" = "1" ]; then PASS=$((PASS+1)); echo "  ok  $2"; else FAIL=$((FAIL+1)); echo "  FAIL $2"; fi; }
b() { if [ "$1" = "0" ]; then echo 1; else echo 0; fi; }   # exit-code -> ok flag

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.claude/agents" "$TMP/.claude/commands" "$TMP/.claude/skills/proj-thing" \
         "$TMP/.claude/skills/e2e-evidence" "$TMP/.claude/hooks" "$TMP/harness/lib" "$TMP/state" "$TMP/specs"

# --- IDENTICAL: copy plugin files verbatim ---
cp "$PLUGIN/agents/explorer.md"           "$TMP/.claude/agents/explorer.md"
cp "$PLUGIN/commands/handoff.md"          "$TMP/.claude/commands/handoff.md"
cp "$PLUGIN/skills/e2e-evidence/SKILL.md" "$TMP/.claude/skills/e2e-evidence/SKILL.md"
cp "$PLUGIN/hooks/protect-specs.sh"       "$TMP/.claude/hooks/protect-specs.sh"
cp "$PLUGIN/hooks/block-destructive.ps1"  "$TMP/.claude/hooks/block-destructive.ps1"
cp "$PLUGIN/engine/lib/gate.sh"           "$TMP/harness/lib/gate.sh"
cp "$PLUGIN/engine/harness.schema.json"   "$TMP/harness/harness.schema.json"

# --- DIFFERS: a ratcheted block-destructive.sh (copy, then append a denylist pattern) ---
BD="$TMP/.claude/hooks/block-destructive.sh"
cp "$PLUGIN/hooks/block-destructive.sh" "$BD"
printf '# RATCHET: block terraform destroy (added by this project)\n' >> "$BD"
cp "$BD" "$TMP/bd.orig"

# --- PROJECT-ONLY: a project-authored skill ---
printf '# proj-thing\nA project-authored skill with no plugin counterpart.\n' > "$TMP/.claude/skills/proj-thing/SKILL.md"

# --- PROJECT-ONLY hook whose filename EMBEDS an engine hook name (finding 3 decoy) ---
printf '#!/usr/bin/env bash\n# project-owned hook — must NOT be stripped as block-destructive\n' > "$TMP/.claude/hooks/my-block-destructive.sh"

# --- Runners: DIFFERS copies of the engine scripts (become wrappers with --replace-runners) ---
for rn in loop.ps1 loop.sh fleet.ps1 fleet.sh; do
  cp "$ENGINE/$rn" "$TMP/harness/$rn"
  printf '# local tweak %s\n' "$rn" >> "$TMP/harness/$rn"
done

# --- Never-touched scaffold ---
printf '%s' '{ "autonomy": { "mode": "supervised" }, "verification": {} }' > "$TMP/harness/harness.config.json"
printf '# Project map (must not be touched)\n' > "$TMP/CLAUDE.md"
printf '# notes (must not be touched)\n'       > "$TMP/AGENT_NOTES.md"
printf 'log\n'  > "$TMP/state/PROGRESS.md"
printf 'spec\n' > "$TMP/specs/000.md"
cfg_sum="$(cksum < "$TMP/harness/harness.config.json")"
claude_sum="$(cksum < "$TMP/CLAUDE.md")"
notes_sum="$(cksum < "$TMP/AGENT_NOTES.md")"
spec_sum="$(cksum < "$TMP/specs/000.md")"

# --- settings.json: all 5 engine hooks + one project hook + model + permissions ---
SETTINGS="$TMP/.claude/settings.json"
cat > "$SETTINGS" <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "opus",
  "permissions": {
    "allow": ["Read", "Edit", "Write"],
    "deny": ["Read(./**/.env)"]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|PowerShell", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/block-destructive.sh\"", "timeout": 30 } ] },
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/protect-specs.sh\"", "timeout": 30 } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/project-notify.sh\"", "timeout": 10 } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/my-block-destructive.sh\"", "timeout": 10 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/format-and-check.sh\"", "timeout": 120 } ] }
    ],
    "ConfigChange": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/lock-config.sh\"", "timeout": 15 } ] }
    ],
    "SessionStart": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/session-start.sh\"", "timeout": 30 } ] }
    ]
  }
}
JSON

# === REPORT (no flags): classifies, writes nothing ===
echo "migrate: report (no flags)"
out="$(bash "$MIGRATE" --project-root "$TMP" 2>&1)"; rc=$?
ok "$(b $rc)" "report exits 0"
ok "$(printf '%s' "$out" | grep -q 'IDENTICAL'    && echo 1 || echo 0)" "report shows IDENTICAL class"
ok "$(printf '%s' "$out" | grep -q 'DIFFERS'      && echo 1 || echo 0)" "report shows DIFFERS class"
ok "$(printf '%s' "$out" | grep -q 'PROJECT-ONLY' && echo 1 || echo 0)" "report shows PROJECT-ONLY class"
ok "$(printf '%s' "$out" | grep -q 'block-destructive.sh' && echo 1 || echo 0)" "report names the ratcheted hook"
ok "$(printf '%s' "$out" | grep -q 'proj-thing'   && echo 1 || echo 0)" "report names the project skill"
ok "$([ -f "$TMP/harness/lib/gate.sh" ] && echo 1 || echo 0)" "report wrote nothing (IDENTICAL file still present)"
ok "$([ ! -f "$TMP/harness/MIGRATION-REPORT.md" ] && echo 1 || echo 0)" "report wrote no MIGRATION-REPORT.md"

if ! command -v jq >/dev/null 2>&1; then
  echo "  (skipping --apply asserts — jq not installed)"
  echo
  echo "RESULT: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# === APPLY without --force on a NON-git target must REFUSE (finding 4) ===
echo "migrate: --apply on non-git without --force (must refuse)"
bash "$MIGRATE" --project-root "$TMP" --apply >/dev/null 2>&1; rc_nf=$?
ok "$([ "$rc_nf" != "0" ] && echo 1 || echo 0)" "non-git --apply without --force exits non-zero"
ok "$([ -f "$TMP/harness/lib/gate.sh" ] && echo 1 || echo 0)" "non-git --apply without --force changed nothing"

# === APPLY ===
echo "migrate: --apply --replace-runners --force"
out2="$(bash "$MIGRATE" --project-root "$TMP" --apply --replace-runners --force 2>&1)"; rc2=$?
ok "$(b $rc2)" "apply exits 0"

# Preservations
ok "$([ -f "$BD" ] && echo 1 || echo 0)" "ratcheted block-destructive.sh still present"
ok "$(cmp -s "$BD" "$TMP/bd.orig" && echo 1 || echo 0)" "ratcheted hook is byte-for-byte UNCHANGED"
ok "$([ -f "$TMP/.claude/skills/proj-thing/SKILL.md" ] && echo 1 || echo 0)" "project skill proj-thing/SKILL.md still present"

# Removals (IDENTICAL)
ok "$([ ! -f "$TMP/harness/lib/gate.sh" ] && echo 1 || echo 0)"          "IDENTICAL harness/lib/gate.sh removed"
ok "$([ ! -f "$TMP/.claude/agents/explorer.md" ] && echo 1 || echo 0)"  "IDENTICAL .claude/agents/explorer.md removed"
ok "$([ ! -f "$TMP/.claude/hooks/protect-specs.sh" ] && echo 1 || echo 0)" "IDENTICAL protect-specs.sh removed"
ok "$([ ! -f "$TMP/harness/harness.schema.json" ] && echo 1 || echo 0)" "IDENTICAL harness.schema.json removed"
ok "$([ ! -d "$TMP/harness/lib" ] && echo 1 || echo 0)"                 "emptied harness/lib dir pruned"
ok "$([ -d "$TMP/.claude/skills" ] && echo 1 || echo 0)"                "skills dir kept (proj-thing survives)"

# settings.json surgery
ok "$(jq -e . "$SETTINGS" >/dev/null 2>&1 && echo 1 || echo 0)" "settings.json still valid JSON"
# block-destructive.sh is DIFFERS-kept (ratchet) => its wiring MUST be kept so the ratchet keeps firing.
ok "$(grep -q 'hooks/block-destructive\.sh' "$SETTINGS" && echo 1 || echo 0)" "settings KEEPS block-destructive.sh wiring (DIFFERS ratchet)"
ok "$(grep -q 'my-block-destructive' "$SETTINGS" && echo 1 || echo 0)" "settings KEEPS my-block-destructive wiring (left-boundary, finding 3)"
ok "$([ -f "$TMP/.claude/hooks/my-block-destructive.sh" ] && echo 1 || echo 0)" "project hook my-block-destructive.sh kept"
ok "$(grep -q 'protect-specs'     "$SETTINGS" && echo 0 || echo 1)" "settings lost protect-specs wiring (IDENTICAL removed)"
ok "$(grep -q 'format-and-check'  "$SETTINGS" && echo 0 || echo 1)" "settings lost format-and-check wiring"
ok "$(grep -q 'lock-config'       "$SETTINGS" && echo 0 || echo 1)" "settings lost lock-config wiring"
ok "$(grep -q 'session-start'     "$SETTINGS" && echo 0 || echo 1)" "settings lost session-start wiring"
ok "$(grep -q 'project-notify'    "$SETTINGS" && echo 1 || echo 0)" "settings KEEPS the project-specific hook"
ok "$([ "$(jq -r '.model' "$SETTINGS")" = "opus" ] && echo 1 || echo 0)" "settings KEEPS model=opus"
ok "$(jq -e '.permissions.allow | index("Read")' "$SETTINGS" >/dev/null 2>&1 && echo 1 || echo 0)" "settings KEEPS permissions.allow"
ok "$(jq -e '.hooks | has("PostToolUse") | not' "$SETTINGS" >/dev/null 2>&1 && echo 1 || echo 0)" "emptied hook events pruned (no PostToolUse)"
ok "$(jq -e '.hooks | has("PreToolUse")' "$SETTINGS" >/dev/null 2>&1 && echo 1 || echo 0)" "PreToolUse survives (project hook)"

# Runner wrappers
wrap_ok=1; bak_ok=1
for rn in loop.ps1 loop.sh fleet.ps1 fleet.sh; do
  rp="$TMP/harness/$rn"
  { [ -f "$rp" ] && grep -q 'HARNESS_ENGINE' "$rp"; } || wrap_ok=0
  [ -f "$TMP/harness/$rn.pre-plugin.bak" ] || bak_ok=0
done
ok "$wrap_ok" "all 4 runners replaced by wrappers"
ok "$bak_ok"  "all 4 runners backed up to .pre-plugin.bak"

# Never-touched scaffold
ok "$([ "$(cksum < "$TMP/harness/harness.config.json")" = "$cfg_sum" ] && echo 1 || echo 0)" "harness.config.json untouched"
ok "$([ "$(cksum < "$TMP/CLAUDE.md")" = "$claude_sum" ] && echo 1 || echo 0)"                "CLAUDE.md untouched"
ok "$([ "$(cksum < "$TMP/AGENT_NOTES.md")" = "$notes_sum" ] && echo 1 || echo 0)"            "AGENT_NOTES.md untouched"
ok "$([ "$(cksum < "$TMP/specs/000.md")" = "$spec_sum" ] && echo 1 || echo 0)"               "specs/ untouched"

# Report file
REP="$TMP/harness/MIGRATION-REPORT.md"
ok "$([ -f "$REP" ] && echo 1 || echo 0)" "MIGRATION-REPORT.md written"
ok "$( { grep -q 'Removed' "$REP" && grep -q 'DIFFERS' "$REP" && grep -q 'PROJECT-ONLY' "$REP"; } && echo 1 || echo 0)" "report lists Removed / DIFFERS / PROJECT-ONLY"
ok "$( { grep -q 'WARN' "$REP" && grep -q 'block-destructive' "$REP"; } && echo 1 || echo 0)" "report warns the customized hook's wiring was KEPT"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
