#!/usr/bin/env bash
# The worktree lives under c:\users\<you>\repos\<repo>, which IS trusted in the persisted
# ~/.codex/config.toml. If Codex trust is prefix-based this replicates V5's exact condition
# (real persisted trust) without touching the user's config at all.
set -u
P="$1"
REAL="$P/.codex/config.toml"
BAK="$(mktemp)"; cp "$REAL" "$BAK"
trap 'cp "$BAK" "$REAL"; rm -f "$BAK"' EXIT

probe() {  # $1 label
  local out
  out="$( (cd "$P" && codex exec --sandbox read-only "reply with exactly: PONG" 2>&1 </dev/null) )"
  local e m
  e="$(printf '%s' "$out" | grep -iE 'error loading|invalid type|missing field|expected struct|parse' | head -1)"
  m="$(printf '%s' "$out" | grep -E '^model' | head -1)"
  printf '  %-38s %-22s %s\n' "$1" "$m" "${e:-<no config error>}"
}

echo "project (trusted-by-prefix): $P"
echo

echo "1. SHIPPED config (should be clean either way)"
probe "as generated"

echo
echo "2. V5's two fatal shapes — if the file is read, these MUST error"
printf '[features]\nhooks = true\n[[skills.config]]\npath = "/tmp/none"\n' > "$REAL"
probe "skills.config WITHOUT enabled"
printf '[features]\nhooks = true\n[agents]\nenabled = true\n' > "$REAL"
probe "[agents] enabled = true"

echo
echo "3. syntactically invalid TOML — any parser must reject"
printf 'this is not = = valid toml [[[\n' > "$REAL"
probe "invalid toml"

echo
echo "4. observable override — model set in the PROJECT config"
printf 'model = "gpt-5-codex"\n[features]\nhooks = true\n' > "$REAL"
probe "project config sets model"
