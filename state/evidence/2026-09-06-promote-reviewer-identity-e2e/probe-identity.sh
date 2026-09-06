#!/usr/bin/env bash
# Stage 3 — the reviewer-identity gate, resolved against a REAL pull request with REAL GitHub calls.
#
# This is the half that unit tests cannot reach: /promote §6 reads a token out of the env var named by
# `promotion.reviewer.tokenEnv`, asks GitHub who that token is, and refuses AUTO unless the answer
# differs from the PR's author. Four token states are exercised against the same live PR.
#
# It is READ-ONLY against GitHub: the only API call is `gh api user` (GET /user) plus `gh pr view`.
# There is no `gh pr review` and no `gh pr merge` anywhere in this file, and §8's post-run check below
# re-reads the PR to show its review state never changed.
#
# Tokens are read into a local and passed to one child process. They are never echoed, never written
# to a file, and never committed — only the LOGIN each one resolves to is recorded.
set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
ENGINE="${HARNESS_ENGINE:-$REPO/plugin/engine}"
EVID="$REPO/state/evidence/2026-09-06-promote-reviewer-identity-e2e"
SHADOW="$EVID/probe-config.shadow.json"
. "$ENGINE/lib/risk.sh"

echo "=== §9 probes (any failure => HUMAN, never merge) ==="
gh --version | head -1
gh auth status 2>&1 | sed -e 's/gho_[A-Za-z0-9_]*/<redacted>/g' | grep -E 'Logged in|Active account|Token scopes' | head -6
echo

echo "=== §1 bind to the PR ==="
PRJSON="$(gh pr view --json number,state,headRefOid,baseRefName,author 2>/dev/null)"
if [ -z "$PRJSON" ]; then echo "no PR for this branch => HUMAN (fail-closed); nothing further to prove"; exit 0; fi
PR_NUM="$(jq -r .number       <<< "$PRJSON")"
PR_STATE="$(jq -r .state      <<< "$PRJSON")"
PR_HEAD="$(jq -r .headRefOid  <<< "$PRJSON")"
PR_BASE="$(jq -r .baseRefName <<< "$PRJSON")"
AUTHOR="$(jq -r .author.login <<< "$PRJSON")"
LOCAL_HEAD="$(git rev-parse HEAD)"
WANT_BASE="$(jq -r '.promotion.staging.branch' "$REPO/harness/harness.config.json")"

printf 'PR #%s  state=%s  author=%s\n' "$PR_NUM" "$PR_STATE" "$AUTHOR"
printf '  head binding : PR %s vs local HEAD %s  => %s\n' "${PR_HEAD:0:12}" "${LOCAL_HEAD:0:12}" \
  "$([ "$PR_HEAD" = "$LOCAL_HEAD" ] && echo BOUND || echo 'MISMATCH => HUMAN')"
printf '  base binding : PR base "%s" vs promotion.staging.branch "%s" => %s\n' "$PR_BASE" "$WANT_BASE" \
  "$([ "$PR_BASE" = "$WANT_BASE" ] && echo BOUND || echo 'MISMATCH => HUMAN')"
BOUND=1
[ "$PR_STATE" = "OPEN" ]          || BOUND=0
[ "$PR_HEAD"  = "$LOCAL_HEAD" ]   || BOUND=0
[ "$PR_BASE"  = "$WANT_BASE" ]    || BOUND=0
printf '  => binding %s\n\n' "$([ "$BOUND" = 1 ] && echo holds || echo 'FAILED (this run can never reach AUTO)')"

# /promote §6, executed literally: env var -> token -> login -> compare with the author.
reviewer_bool() {  # $1 env var name ; echoes "<0|1>|<reason>|<login-or-empty>"
  local var="$1" tok login rc
  tok="$(eval "printf '%s' \"\${$var:-}\"")"
  [ -n "$tok" ] || { echo "0|reviewer identity not configured|"; return; }
  # BOTH checks, per /promote §6.3. On a bad token `gh api user` exits non-zero but prints its error
  # body to STDOUT, so a non-empty capture is not evidence of success: the first version of this probe
  # kept only stdout, captured `{ "message": "Bad credentials" ... }`, found it != the author, and
  # returned reviewer=1 -> AUTO. That is the fail-open this batch documents.
  login="$(GH_TOKEN="$tok" gh api user --jq .login 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "0|reviewer identity could not be resolved (gh api user exit $rc)|"; return; }
  grep -qE '^[A-Za-z0-9](-?[A-Za-z0-9])*$' <<< "$login" \
    || { echo "0|reviewer identity could not be resolved (response is not a login)|"; return; }
  [ "$login" != "$AUTHOR" ] || { echo "0|reviewer identity equals author|$login"; return; }
  echo "1|separate reviewer identity resolved|$login"
}

case_run() {  # $1 label  $2 env var name
  local label="$1" var="$2" r rev reason login dec
  r="$(reviewer_bool "$var")"
  rev="${r%%|*}"; reason="$(cut -d'|' -f2 <<< "$r")"; login="$(cut -d'|' -f3 <<< "$r")"
  # LOW tier both sides, all preconditions met: the reviewer boolean is the ONLY variable.
  dec="$(promotion_decision "$SHADOW" staging LOW LOW 1 1 1 "$rev")"
  printf '%-28s reviewer=%s  login=%-16s %s\n' "$label" "$rev" "${login:-<none>}" "$reason"
  printf '    decision: %s\n\n' "$dec"
}

echo "=== §6 the reviewer-identity gate, four real token states, same LOW range ==="
echo "(the author of PR #$PR_NUM is $AUTHOR — that is what each resolved login is compared against)"
echo

unset HARNESS_PROMOTE_REVIEWER_TOKEN
case_run "1. env var unset" HARNESS_PROMOTE_REVIEWER_TOKEN

HARNESS_PROMOTE_REVIEWER_TOKEN="not-a-real-token" case_run "2. invalid token" HARNESS_PROMOTE_REVIEWER_TOKEN

# The author's OWN token: resolves fine, but to the author — the self-approval GitHub would reject.
HARNESS_PROMOTE_REVIEWER_TOKEN="$(gh auth token --user "$AUTHOR" 2>/dev/null)" \
  case_run "3. the author's own token" HARNESS_PROMOTE_REVIEWER_TOKEN

# The separate write identity the S3 proof established (PR #9): a second account, write collaborator.
HARNESS_PROMOTE_REVIEWER_TOKEN="$(gh auth token --user jl-pr-reviewer 2>/dev/null)" \
  case_run "4. the separate reviewer" HARNESS_PROMOTE_REVIEWER_TOKEN

echo "=== gh-unavailable fails closed ==="
# Strip gh from PATH and re-run the §9 probe exactly as /promote would.
if PATH=/usr/bin:/bin command -v gh >/dev/null 2>&1; then
  echo "  (gh still reachable on the stripped PATH; skipping)"
else
  echo "  gh --version on a stripped PATH: $(PATH=/usr/bin:/bin gh --version 2>&1 | head -1 || true)"
  echo "  => probe fails => HUMAN path, and §6 never runs (no identity, no approve, no merge)"
fi
echo

echo "=== nothing was approved or merged ==="
gh pr view "$PR_NUM" --json state,reviewDecision,mergedAt,reviews \
  --jq '{state, reviewDecision, mergedAt, reviewCount: (.reviews|length)}'
