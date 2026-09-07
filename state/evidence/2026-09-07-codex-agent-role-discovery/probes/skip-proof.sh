#!/usr/bin/env bash
# Proof that PROBE_SKIP_MODEL=1 actually suppresses EVERY paid arm.
#
# WHY: the README said "set PROBE_SKIP_MODEL=1 to run only the free parts" while only two of
# the five model-calling scripts read the variable — 7 of 9 paid arms fired anyway. Anyone
# following the README to re-run these cheaply would have paid for all of them. A cost switch
# that is documented but unhonoured is worse than none, because it is trusted.
#
# Method: run every probe script with PROBE_SKIP_MODEL=1 under a PATH that shadows `codex`
# with a stub which FAILS LOUDLY if invoked with `exec` (a real model call) and answers
# normally for the free subcommands. Nothing here calls the network.
set -uo pipefail
cd "$(dirname "$0")"

stub_dir="$(mktemp -d)"
trap 'rm -f "$stub_dir"/codex "$stub_dir"/marker 2>/dev/null; rmdir "$stub_dir" 2>/dev/null || true' EXIT

cat > "$stub_dir/codex" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  exec) echo "PAID-ARM-FIRED: codex exec was invoked under PROBE_SKIP_MODEL" >&2
        echo fired >> "$STUB_MARKER"; exit 97;;
  --version) echo "codex-cli 0.153.4-stub";;
  doctor)   echo "stub doctor: no findings";;
  agents)   echo "stub agents: Browse all agent sessions";;
  *)        echo "stub: $*";;
esac
exit 0
STUB
chmod +x "$stub_dir/codex"

export STUB_MARKER="$stub_dir/marker"
: > "$STUB_MARKER"
export PATH="$stub_dir:$PATH"
export PROBE_SKIP_MODEL=1

rc=0
for f in role-discovery.sh role-visible.sh role-visible-real.sh doctor-and-baseline.sh \
         spawn-and-tempdir.sh spawn-control.sh; do
  echo "--- $f"
  bash "$f" >/dev/null 2>&1 || echo "    (exited non-zero; that alone is not a failure here)"
done

if [ -s "$STUB_MARKER" ]; then
  echo "FAIL: a paid arm fired despite PROBE_SKIP_MODEL=1"
  cat "$STUB_MARKER"
  rc=1
else
  echo "PASS: no script invoked 'codex exec' under PROBE_SKIP_MODEL=1"
fi

# NEGATIVE CONTROL. Without the switch, the same stub MUST record a firing — otherwise this
# proof would pass against a script that never calls codex at all, which is the "tool that
# silently does nothing" failure the sibling scrub-proof.sh was written for.
echo "--- negative control: same stub, PROBE_SKIP_MODEL unset"
: > "$STUB_MARKER"
( unset PROBE_SKIP_MODEL; bash role-visible-real.sh >/dev/null 2>&1 || true )
if [ -s "$STUB_MARKER" ]; then
  echo "PASS: the stub does detect a paid arm when the switch is off"
else
  echo "FAIL: the stub never fired even with the switch off - this proof cannot discriminate"
  rc=1
fi

# Restore a clean .codex for the repo: the scripts above rewrite it as they go.
rm -rf ../../../../.codex 2>/dev/null || true
exit "$rc"
