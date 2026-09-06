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
echo "A. model set at TOP LEVEL (the real override; header would change if read)"
printf 'model = "gpt-5-codex"\n[features]\nhooks = true\n' > "$REAL"
printf '  %s\n' "$(hdr)"

echo
echo "A2. model nested INSIDE [features] — not a valid override position, kept as a foil"
printf '[features]\nhooks = true\nmodel = "gpt-5-codex"\n' > "$REAL"
printf '  %s\n' "$(hdr)"

echo
echo "B. syntactically INVALID toml (any parser must reject it)"
printf 'this is not = = valid toml [[[\n' > "$REAL"
printf '  %s\n' "$(hdr)"

# POSITIVE CONTROL, in the script rather than in prose. Everything above is a NEGATIVE result, and a
# negative is worthless unless the mechanism it relies on demonstrably works. These two rows prove
# (a) `-c` overrides DO reach the config in this very invocation, and (b) the trust key specifically
# is ignored -- so "no error" above means "the file was not read", not "-c was broken".
echo
echo "CONTROLS (with the invalid toml still in place):"
W="$(cygpath -m "$P" 2>/dev/null | tr 'A-Z' 'a-z' | tr '/' '\\')"
printf '  -c model=... (must CHANGE the header): %s\n' \
  "$( (cd "$P" && codex exec --sandbox read-only --skip-git-repo-check -c 'model="gpt-5-codex"' \
       "reply with exactly: PONG" 2>&1 </dev/null) | grep -E '^model' | head -1)"
printf '  -c trust_level=trusted (must NOT rescue the file): %s\n' \
  "$( (cd "$P" && codex exec --sandbox read-only --skip-git-repo-check -c "projects.'$W'.trust_level=\"trusted\"" \
       "reply with exactly: PONG" 2>&1 </dev/null) | grep -ciE 'error|parse' | sed 's/^/error-lines=/')"
