#!/usr/bin/env bash
# Review should-fix #3 and #4: the "silently, no warning" claim was made from a GREP-FILTERED probe,
# which cannot prove absence; and the `codex doctor` claim had no recorded output at all.
# Capture the FULL output of an untrusted project with an invalid project config, and doctor's
# configuration section in both an untrusted and a trusted project.
set -u
UNTRUSTED="$1"     # /tmp/cxproj  (not under any [projects.…] entry)
TRUSTED="$2"       # the worktree (inherits its repo's entry by prefix)

echo "############ 1. UNTRUSTED project, project config is INVALID TOML ############"
echo "#### full unfiltered output follows; grep nothing away ####"
printf 'this is not = = valid toml [[[\n' > "$UNTRUSTED/.codex/config.toml"
(cd "$UNTRUSTED" && codex exec --sandbox read-only --skip-git-repo-check "reply with exactly: PONG" 2>&1 </dev/null)
echo "#### end ####"
echo
echo "############ 2. codex doctor — configuration section, UNTRUSTED project ############"
(cd "$UNTRUSTED" && codex doctor 2>&1 | sed -n '/^Configuration/,/^  . auth/p')
echo
echo "############ 3. codex doctor — configuration section, TRUSTED project ############"
(cd "$TRUSTED" && codex doctor 2>&1 | sed -n '/^Configuration/,/^  . auth/p')
