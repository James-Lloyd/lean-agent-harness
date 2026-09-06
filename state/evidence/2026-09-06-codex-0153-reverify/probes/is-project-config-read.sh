#!/usr/bin/env bash
# Is <project>/.codex/config.toml read by Codex 0.153.4 at all?
# Two observable signals, neither relying on absence-of-error:
#   A. an override the header would SHOW  (model = ...)
#   B. syntactically invalid TOML, which any parser must reject
set -u
P="$1"
REAL="$P/.codex/config.toml"
BAK="$(mktemp)"; cp "$REAL" "$BAK"
restore() { cp "$BAK" "$REAL"; rm -f "$BAK"; }
trap restore EXIT

hdr() {  # echoes the "model:" line codex prints for a run in $P
  (cd "$P" && codex exec --sandbox read-only --skip-git-repo-check "reply with exactly: PONG" 2>&1 </dev/null) \
    | grep -E '^(model|ERROR|error)' | head -2 | tr '\n' ' '
}

echo "baseline: no project config at all"
mv "$REAL" "$REAL.hidden"
printf '  %s\n' "$(hdr)"
mv "$REAL.hidden" "$REAL"

echo
echo "A. project config sets model = \"gpt-5-codex\" (header would change if read)"
printf '[features]\nhooks = true\nmodel = "gpt-5-codex"\n' > "$REAL"
printf '  %s\n' "$(hdr)"

echo
echo "A2. same, model at top level before [features]"
printf 'model = "gpt-5-codex"\n[features]\nhooks = true\n' > "$REAL"
printf '  %s\n' "$(hdr)"

echo
echo "B. syntactically INVALID toml (any parser must reject it)"
printf 'this is not = = valid toml [[[\n' > "$REAL"
printf '  %s\n' "$(hdr)"
