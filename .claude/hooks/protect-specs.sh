#!/usr/bin/env bash
# PreToolUse(Edit|Write|MultiEdit) hook — make specs/ immutable DURING an unattended loop run
# (bash mirror of protect-specs.ps1). Mechanizes the "specs are the contract; never edit them" guardrail
# in the headless auto context where prose isn't enough. Exit 2 + stderr => block; exit 0 => allow.
#
# Env-gated: only blocks when HARNESS_LOCK_SPECS is set (loop.sh/loop.ps1 set it before invoking the
# model). Interactive sessions leave it unset, so /plan, /harness-init, /onboard can still author specs.
[ -z "${HARNESS_LOCK_SPECS:-}" ] && exit 0
payload="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
# NotebookEdit carries `notebook_path`, not `file_path` — fall back so specs/*.ipynb is covered too.
changed="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -z "$changed" ] && exit 0

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"; root="${root%/}"
# Normalize the path (resolve ../ etc.) for parity with the .ps1, which GetFullPath-normalizes.
if command -v realpath >/dev/null 2>&1; then changed="$(realpath -m "$changed" 2>/dev/null || echo "$changed")"; fi
case "$changed" in
  "$root"/*) rel="${changed#"$root"/}";;
  *) rel="$changed";;
esac

# Case-insensitive match (mirror the .ps1, which is case-insensitive) so Specs/ is caught on
# case-insensitive filesystems. NOTE: this does not normalize `..` segments — Edit/Write pass clean
# absolute paths, but an exotic `foo/../specs/x` would slip past the bash hook (the .ps1 normalizes).
shopt -s nocasematch
case "$rel" in
  specs/*|specs)
    echo "BLOCKED by harness guardrail: specs/ is immutable while the loop runs (HARNESS_LOCK_SPECS is set)." >&2
    echo "Specs are the contract - not a place to record what you built. If a spec is wrong, stop and write the question to state/handoff.md under 'Needs human decision'." >&2
    exit 2;;
esac
exit 0
