#!/usr/bin/env bash
# ConfigChange hook — veto settings/config changes DURING a locked loop run (mirror of lock-config.ps1).
# The loop pins harness/harness.config.json by hash; this extends "don't rewrite your own gate/policy
# mid-run" to the settings surface. Env-gated: HARNESS_LOCK_SPECS is set only by loop.sh/loop.ps1, so
# interactive /harness-init and /update-config are unaffected. Exit 2 + stderr => block.
cat >/dev/null
[ -z "${HARNESS_LOCK_SPECS:-}" ] && exit 0
echo "BLOCKED by harness guardrail: configuration changes are frozen while the loop runs (HARNESS_LOCK_SPECS is set)." >&2
echo "The gate/policy must not be rewritten mid-run. If a config change is genuinely needed, stop the loop first and ask the human." >&2
exit 2
