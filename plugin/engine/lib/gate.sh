#!/usr/bin/env bash
# gate.sh — the verification gate (bash mirror of gate.ps1).
# Harness defines WHEN; each component's gate (+ a cross-cutting root gate) defines WHAT. null => skip.
# Multi-component aware: each component runs in its own dir; root gate runs from repo root last.
# Silent success, verbose failure. Sets GATE_FAILED_STEP="<component>:<step>" on failure.
GATE_FAILED_STEP=""

# Parse a fresh-context reviewer's verdict from stdin: echoes SHIP | REJECT | NONE. FAIL-CLOSED on
# purpose: only the LAST line that STARTS with VERDICT: counts — a preamble mentioning "VERDICT: SHIP"
# mid-reasoning must never pass a batch. Mirror of Get-ReviewVerdict in gate.ps1; lives here so the
# self-tests can exercise it.
review_verdict() {
  local line
  line="$(grep -E '^[[:space:]]*VERDICT:' | tail -1 || true)"
  if printf '%s' "$line" | grep -qE '^[[:space:]]*VERDICT:[[:space:]]*SHIP([[:space:]]|$)'; then echo SHIP
  elif printf '%s' "$line" | grep -qE '^[[:space:]]*VERDICT:[[:space:]]*REJECT([[:space:]]|$)'; then echo REJECT
  else echo NONE; fi
}

# Per-phase model routing: echo config.models.<phase>'s PRIMARY model, or "" when null/absent (= inherit
# the CLI's ambient default — the pre-routing behavior, and what a config trimmed by /harness-prune
# degrades to). Tolerant of BOTH shapes: the new nested {model, fallback} object AND the legacy flat
# 'phase':'alias' string. SPECIAL CASE 'reviewFallback' (a pseudo-phase the review path still asks for):
# resolves to review.fallback (nested) or the legacy top-level models.reviewFallback.
# Mirror of Resolve-PhaseModel in gate.ps1; lives here so the self-tests can exercise it.
phase_model() {  # $1 config path  $2 phase
  local config="$1" p="$2"
  if [ "$p" = "reviewFallback" ]; then
    jq -r '
      (.models.review) as $r
      | if ($r|type) == "object" and $r.fallback != null then $r.fallback
        elif .models.reviewFallback != null then .models.reviewFallback
        else "" end' "$config"
    return
  fi
  jq -r --arg p "$p" '
    (.models[$p]) as $m
    | if ($m|type) == "object" then ($m.model // "")
      elif ($m|type) == "string" then $m
      else "" end' "$config"
}

# Per-phase FALLBACK model: echo config.models.<phase>.fallback, or "" when there is none. Nested
# {model, fallback} returns its .fallback; a legacy flat string has no per-phase fallback.
# Mirror of Resolve-PhaseFallback in gate.ps1.
# SPECIAL CASE review (S1b): must be SYMMETRIC with phase_model reviewFallback — review.fallback if
# non-null, else the legacy top-level models.reviewFallback if non-null, else "" — for the nested-null,
# flat-string, AND absent-review shapes alike (a mixed config had the two accessors disagree otherwise).
phase_fallback() {  # $1 config path  $2 phase
  local config="$1" p="$2"
  if [ "$p" = "review" ]; then
    jq -r '
      (.models.review) as $r
      | if ($r|type) == "object" and $r.fallback != null then $r.fallback
        elif .models.reviewFallback != null then .models.reviewFallback
        else "" end' "$config"
    return
  fi
  jq -r --arg p "$p" '
    (.models[$p]) as $m
    | if ($m|type) == "object" then ($m.fallback // "")
      else "" end' "$config"
}

# Vendor-neutral usage/limit detector (mirror of Test-UsageLimitError). Output-based; $2 exit code is
# reserved for forward-compat (S3 passes it) and not yet decisive. bash 3.2 / BSD-grep safe (no \b).
usage_limit_error() {  # $1 output text  $2 exit code (reserved) ; return 0 if a usage/limit marker present
  local out="$1"
  printf '%s' "$out" | grep -qiE 'usage[ _-]?limit|rate[ _-]?limit|quota|overloaded|too many requests' && return 0
  printf '%s' "$out" | grep -qiE '(http|status|error|code)[^0-9]{0,6}429' && return 0
  return 1
}

# Sandbox detection for unattended `auto` runs. Mirror of Test-Sandboxed in gate.ps1; lives here so the
# self-tests can exercise it. Contract: the env var HARNESS_SANDBOX is the EXPLICIT, cross-platform signal
# and ALWAYS wins when it is SET — truthy (1/true/yes, case-insensitive) => sandboxed; anything else
# (0/false/no/empty) => NOT sandboxed, even inside a container. Only when HARNESS_SANDBOX is UNSET do we
# auto-detect common container markers (ANY present => sandboxed). Returns 0 (sandboxed) / 1 (not).
# On Windows/pwsh the /proc and /.dockerenv probes simply won't match — the env var is the portable
# contract there (the PS runner is the host case).
is_sandboxed() {
  if [ -n "${HARNESS_SANDBOX+x}" ]; then          # SET (even to empty) => the explicit signal wins
    case "$(printf '%s' "${HARNESS_SANDBOX}" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes) return 0 ;;
      *)          return 1 ;;
    esac
  fi
  [ -f /.dockerenv ] && return 0                  # docker
  [ -f /run/.containerenv ] && return 0           # podman
  # Marker env vars are PRESENCE markers: a runtime SETS them to signal itself, so any one being set
  # (even to empty) => sandboxed. Use ${VAR+x} (set-ness), NOT ${VAR:-} (non-empty) or a truthy test —
  # `container` in particular holds a runtime NAME (e.g. "lxc"/"podman"), not a boolean.
  [ -n "${CODESPACES+x}" ] && return 0            # GitHub Codespaces
  [ -n "${REMOTE_CONTAINERS+x}" ] && return 0     # VS Code dev containers
  [ -n "${DEVCONTAINER+x}" ] && return 0          # devcontainer spec
  [ -n "${container+x}" ] && return 0             # systemd-nspawn / podman (value = runtime name)
  if [ -f /proc/1/cgroup ] && grep -qE 'docker|containerd|lxc|kubepods' /proc/1/cgroup 2>/dev/null; then
    return 0
  fi
  return 1
}

_gate_step() {  # $1 name  $2 cmd  $3 workdir
  local name="$1" cmd="$2" workdir="$3"
  { [ "$cmd" = "null" ] || [ -z "$cmd" ]; } && return 0
  echo "  - $name : $cmd"
  local out; out="$(cd "$workdir" && bash -lc "$cmd" 2>&1)" && return 0
  echo "    x $name failed in $workdir:"
  echo "$out" | tail -n 40 | sed 's/^/      /'
  return 1
}

# Run one gate object given a jq path prefix (e.g. '.components[0].gate' or '.gate') in $2 workdir, label $3.
_gate_set() {  # $1 config  $2 jqpath  $3 workdir  $4 label
  local config="$1" jqpath="$2" workdir="$3" label="$4" name cmd
  for name in format lint typecheck build test e2e; do
    cmd="$(jq -r "${jqpath}.${name} // empty" "$config")"
    if ! _gate_step "$name" "$cmd" "$workdir"; then GATE_FAILED_STEP="${label}:${name}"; return 1; fi
  done
  return 0
}

run_gate() {  # $1 = config path ; $REPO_ROOT must be set ; sets GATE_FAILED_STEP on failure
  local config="$1" n i name path label
  n="$(jq -r '.components | length' "$config" 2>/dev/null || echo 0)"
  if [ "$n" = "0" ] || [ "$n" = "null" ]; then
    _gate_set "$config" ".gate" "$REPO_ROOT" "root" || return 1
    return 0
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    # Default a null/absent path to "." (parity with gate.ps1) instead of testing a dir literally
    # named "null" and silently skipping the component's gate (fail-open green on a malformed config).
    name="$(jq -r ".components[$i].name // .components[$i].path // \".\"" "$config")"
    path="$(jq -r ".components[$i].path // \".\"" "$config")"
    echo "  [$name] gate ($path)"
    if [ ! -d "$REPO_ROOT/$path" ]; then
      # FAIL, don't skip: a configured component whose directory is missing is config drift, and a
      # skipped gate would report green without running anything (fail-open).
      echo "  x component '$name' path missing: $path"
      GATE_FAILED_STEP="${name}:path-missing"; return 1
    fi
    _gate_set "$config" ".components[$i].gate" "$REPO_ROOT/$path" "$name" || return 1
    i=$((i+1))
  done
  # cross-cutting root gate, if any non-null step ((.gate // {}) guards a null/absent gate)
  if [ "$(jq -r '[(.gate // {}) | to_entries[] | select(.key != "_comment") | .value] | map(select(. != null and . != "")) | length' "$config")" != "0" ]; then
    echo "  [root] cross-cutting gate"
    _gate_set "$config" ".gate" "$REPO_ROOT" "root(cross-cutting)" || return 1
  fi
  return 0
}
