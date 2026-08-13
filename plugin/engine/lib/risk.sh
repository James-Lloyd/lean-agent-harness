#!/usr/bin/env bash
# risk.sh — risk classification for gated promotion (bash mirror of risk.ps1).
#
# Decides how much HUMAN scrutiny an already-green, already-reviewed diff needs before it is merged
# onward. It does not decide correctness — the gate and the fresh-context reviewer already did.
#
# Three invariants, enforced in code rather than trusted from a prompt:
#  1. ESCALATE-ONLY  — every stage may raise a tier, none may lower it (risk_tier_max is a max()
#     over LOW<MEDIUM<HIGH). A change's author cannot classify its own change as low-risk.
#  2. FAIL-CLOSED    — unparseable / unknown / absent / empty all resolve to HIGH / HUMAN.
#  3. PROD IS NEVER AUTOMATED — promotion_decision refuses prod AUTO before reading any config.
#
# Twin rule: a change lands in risk.ps1 and risk.sh or not at all.

# Paths whose change governs the promotion policy ITSELF, or the guardrails it leans on. HARDCODED,
# deliberately not config-driven: if the escalation list for "edits to the escalation list" lived in
# config, one edit could disarm the mechanism and then auto-merge itself. Keep byte-identical with
# $script:RiskSelfGovernGlobs in risk.ps1.
RISK_SELF_GOVERN_GLOBS='specs/**
harness/harness.config.json
.claude/settings.json
.claude/hooks/**
.github/workflows/**
plugin/hooks/**
plugin/engine/lib/risk.ps1
plugin/engine/lib/risk.sh
plugin/agents/risk-classifier.md
plugin/commands/promote.md
plugin/skills/risk-tiering/**'

# Read config through jq with CR stripped. NOT cosmetic: jq.exe under Git Bash on Windows emits
# CRLF, so a glob read straight out of jq arrives as "**/payments/**\r", compiles to a regex ending
# `.*\r$`, and then silently matches NOTHING. Every rule in this file would fail OPEN — the exact
# direction a risk classifier must never fail. Route every config read through here.
risk_jq() {  # same args as jq
  jq "$@" 2>/dev/null | tr -d '\r' || true
}

# Strip a trailing CR from a value read line-by-line (same hazard as risk_jq, for `read` loops).
strip_cr() { printf '%s' "${1%$'\r'}"; }

# Translate a path glob to an anchored ERE with the SAME semantics as the PS twin (PowerShell -like
# has no `**`, and bash `case` globs cross `/` differently — so neither native mechanism is used).
# `**/` spans zero or more whole segments, `**` spans anything, `*` and `?` never cross `/`.
# Expansion goes through placeholders because the replacements themselves contain `*` and `/`, and a
# naive sequential sed would re-process its own output. Mirror of Convert-GlobToRegex in risk.ps1.
glob_to_regex() {  # $1 glob ; echoes an anchored ERE
  printf '%s' "$1" | sed \
    -e 's|\\|/|g' \
    -e 's/[.+^$(){}|]/\\&/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' \
    -e 's|\*\*/|@@RA@@|g' -e 's|\*\*|@@RB@@|g' -e 's|\*|@@RC@@|g' -e 's|?|@@RD@@|g' \
    -e 's|@@RA@@|(.*/)?|g' -e 's|@@RB@@|.*|g' \
    -e 's|@@RC@@|[^/]*|g'  -e 's|@@RD@@|[^/]|g' \
    -e 's|^|^|' -e 's|$|$|'
}

# Compile a whole glob SET to ONE alternation regex. Compiling per-glob-per-file instead costs a sed
# + a grep fork for every (file, glob) pair: a real 57-file promotion diff against the shipped
# criteria is ~2800 pairs / ~5600 forks, which took MINUTES on Windows and made /promote unusable.
# Compile once per rule group, match in one pass. Mirror of Get-GlobUnionRegex in risk.ps1.
globs_union_regex() {  # $1 newline-separated globs ; echoes an ERE alternation, or "" if none
  local g out=""
  while IFS= read -r g; do
    g="$(strip_cr "$g")"
    [ -n "$g" ] || continue
    if [ -n "$out" ]; then out="$out|$(glob_to_regex "$g")"; else out="$(glob_to_regex "$g")"; fi
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# Normalize a repo-relative path for matching: backslashes to forward, and strip a LEADING './' only
# — never a character-class trim, which would eat the dot of '.github/...' and silently unmatch it.
normalize_path() {  # $1 path
  local p
  p="$(printf '%s' "$1" | tr '\\' '/')"
  while case "$p" in ./*) true ;; *) false ;; esac; do p="${p#./}"; done
  printf '%s' "$p"
}

# Does a repo-relative path match ANY of the newline-separated globs on $2? Returns 0 on match.
# Mirror of Test-PathMatchesAny in risk.ps1.
path_matches_any() {  # $1 path  $2 newline-separated globs
  local p rx
  [ -n "$1" ] || return 1
  rx="$(globs_union_regex "$2")"
  [ -n "$rx" ] || return 1
  p="$(normalize_path "$1")"
  printf '%s' "$p" | grep -qiE "$rx"
}

# Echo every path in the (already normalized) file list $1 that matches ANY glob in $2. One grep for
# the whole group — this is the hot path that keeps /promote fast on a real diff.
paths_matching() {  # $1 normalized-files-file  $2 newline-separated globs
  local rx
  rx="$(globs_union_regex "$2")"
  [ -n "$rx" ] || return 0
  grep -iE "$rx" "$1" 2>/dev/null || true
}

# Rank a tier: LOW=0 MEDIUM=1 HIGH=2. Anything unrecognized ranks HIGH — an unknown tier is not a
# low one. Mirror of Get-RiskRank in risk.ps1.
risk_rank() {  # $1 tier ; echoes 0|1|2
  # TRIM, never delete interior whitespace -- "L OW" must not collapse to LOW (the PS twin's .Trim()
  # leaves it unrecognized, which ranks HIGH; deleting would have ranked it 0).
  case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" in
    LOW)    echo 0 ;;
    MEDIUM) echo 1 ;;
    HIGH)   echo 2 ;;
    *)      echo 2 ;;
  esac
}

# The escalate-only ratchet, in code: echo the HIGHER of two tiers. This is what makes "the agent may
# confirm or raise, never lower" a property of the system rather than a promise in a prompt.
# Mirror of Merge-RiskTier in risk.ps1.
risk_tier_max() {  # $1 tier  $2 tier ; echoes LOW|MEDIUM|HIGH
  local a b hi
  a="$(risk_rank "$1")"; b="$(risk_rank "$2")"
  if [ "$a" -ge "$b" ]; then hi="$a"; else hi="$b"; fi
  case "$hi" in 0) echo LOW ;; 1) echo MEDIUM ;; *) echo HIGH ;; esac
}

# Parse the risk-classifier agent's verdict from stdin: echoes LOW | MEDIUM | HIGH. Mirrors
# review_verdict's fail-closed last-line rule — only the LAST line STARTING with RISK: counts, so a
# mid-reasoning "RISK: LOW would be wrong here" cannot decide the outcome. Any other outcome (no
# text, no RISK: line, an unrecognized token) is HIGH, not a neutral value: the safe direction is
# more human attention, not less. Mirror of Get-RiskVerdict in risk.ps1.
risk_verdict() {
  local line
  line="$(grep -E '^[[:space:]]*RISK:' | tail -1 || true)"
  if printf '%s' "$line" | grep -qE '^[[:space:]]*RISK:[[:space:]]*LOW([[:space:]]|$)'; then echo LOW
  elif printf '%s' "$line" | grep -qE '^[[:space:]]*RISK:[[:space:]]*MEDIUM([[:space:]]|$)'; then echo MEDIUM
  else echo HIGH; fi
}

# Money-signal match against added-diff TEXT (content, not paths): the term must start a word, with
# NO constraint on what follows. NOT \b — BSD grep has no \b and the twins must agree character for
# character, so both emulate the boundary with an explicit class.
#
# Leading boundary only, and `_` counts as a separator (class is [^A-Za-z0-9], not [^A-Za-z0-9_]).
# Deliberate: an earlier trailing-boundary version was wrong in the DANGEROUS direction, missing
# `tax_rate`, `taxes`, `prices`, `amounts` — inflected and snake_case forms are most of how money
# words appear in code, so it silently passed real money diffs as LOW. The cost is a false positive
# on a word that merely STARTS with a money term (`taxonomy`, `balancer`); a false HIGH costs one
# human glance, a false LOW auto-merges a money bug. Mid-word (`syntax` for `tax`) still does not fire.
# Mirror of Test-MoneySignal in risk.ps1.
money_signal() {  # $1 text  $2 term ; returns 0 if present
  local text="$1" term="$2" esc
  [ -n "$text" ] && [ -n "$term" ] || return 1
  esc="$(printf '%s' "$term" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g' -e 's/\]/\\]/g')"
  printf '%s' "$text" | grep -qiE "(^|[^A-Za-z0-9])${esc}"
}

# The deterministic classifier — stage 1, and the only stage that can produce LOW. Every criterion is
# computed FROM THE DIFF, so it cannot be talked around. Each rule can only raise the tier, so the
# order below affects the reason list, never the result.
#   $1 config path   $2 changed lines   $3 file holding changed paths (one per line)
#   $4 file holding the ADDED diff lines (may be /dev/null)
# Echoes "TIER|reason; reason; ...". Mirror of Get-DeterministicRisk in risk.ps1.
deterministic_risk() {
  local config="$1" changed="${2:-0}" files_file="$3" added_file="${4:-/dev/null}"
  local tier=LOW reasons="" files added f term cat maxlines cats catglobs
  # ${2:-0} covers an ABSENT arg but not an empty-string one, and every compare below is arithmetic.
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  files="$(grep -v '^[[:space:]]*$' "$files_file" 2>/dev/null | tr -d '' || true)"
  added="$(cat "$added_file" 2>/dev/null || true)"

  # Fail-closed: nothing to classify is not "low risk", it is a caller bug or a range resolved wrong.
  if [ -z "$files" ] && [ "$changed" -le 0 ]; then
    # ASCII-only inside emitted STRINGS (comments are fine) -- twin parity: PS 5.1 reads a BOM-less
    # .ps1 as ANSI, so a non-ASCII literal would reach the audit record as mojibake there.
    echo "HIGH|empty diff - nothing to classify (fail-closed)"; return
  fi

  # Normalize ONCE, then run one grep per rule group over the whole list (see paths_matching).
  local nf; nf="$(mktemp)"
  while IFS= read -r f; do
    f="$(strip_cr "$f")"; [ -n "$f" ] || continue
    normalize_path "$f"; echo
  done <<EOF > "$nf"
$files
EOF

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    tier="$(risk_tier_max "$tier" HIGH)"
    reasons="${reasons}self-governance: $f (policy, guardrails, or CI); "
  done <<EOF
$(paths_matching "$nf" "$RISK_SELF_GOVERN_GLOBS")
EOF

  local always
  always="$(risk_jq -r '.promotion.alwaysHuman[]? // empty' "$config")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    tier="$(risk_tier_max "$tier" HIGH)"
    reasons="${reasons}alwaysHuman path: $f; "
  done <<EOF
$(paths_matching "$nf" "$always")
EOF

  while IFS= read -r term; do
    term="$(strip_cr "$term")"; [ -n "$term" ] || continue
    if money_signal "$added" "$term"; then
      tier="$(risk_tier_max "$tier" HIGH)"
      reasons="${reasons}money signal '$term' in added lines; "
    fi
  done <<EOF
$(risk_jq -r '.promotion.moneySignals[]? // empty' "$config")
EOF

  maxlines="$(risk_jq -r '.promotion.criteria.maxChangedLines // empty' "$config")"
  if [ -n "$maxlines" ] && [ "$changed" -ge "$maxlines" ]; then
    tier="$(risk_tier_max "$tier" MEDIUM)"
    reasons="${reasons}$changed changed lines (limit $maxlines); "
  fi

  cats="$(risk_jq -r '.promotion.criteria.escalatePaths // {} | keys[]?' "$config")"
  while IFS= read -r cat; do
    cat="$(strip_cr "$cat")"; [ -n "$cat" ] || continue
    catglobs="$(risk_jq -r --arg c "$cat" '.promotion.criteria.escalatePaths[$c][]? // empty' "$config")"
    # First match only: the category is the finding, not each file in it.
    f="$(paths_matching "$nf" "$catglobs" | head -1)"
    if [ -n "$f" ]; then
      tier="$(risk_tier_max "$tier" MEDIUM)"
      reasons="${reasons}$cat: $f; "
    fi
  done <<EOF
$cats
EOF
  rm -f "$nf"

  [ -n "$reasons" ] || reasons="no escalation criterion tripped"
  echo "${tier}|${reasons%"; "}"
}

# Shape-validate the promotion block before ANY of it is trusted. Without this, every degenerate
# shape SKIPS a rule instead of escalating -- the block fails OPEN, contradicting this file's own
# fail-closed contract. Real cases that reached AUTO before this gate existed: `preconditions` absent
# entirely (schema-valid; /harness-prune may trim it) so a red gate + no review SHIP + no e2e evidence
# all passed while the audit string still read "all preconditions met"; and `alwaysHuman`/`moneySignals`
# written as a SCALAR instead of an array (a plausible hand-edit), which made the whole money rule
# evaluate to "no match" so a payments diff classified LOW.
# Echoes "" when well-formed, else a reason. Mirror of Test-PromotionConfigShape in risk.ps1.
promotion_config_shape() {  # $1 config path
  local config="$1" k t n
  if [ "$(risk_jq -r 'has("promotion")' "$config")" != "true" ]; then
    echo "promotion block is absent"; return
  fi
  t="$(risk_jq -r '.promotion.enabled | type' "$config")"
  if [ "$t" != "boolean" ]; then
    echo "promotion.enabled is not a boolean (got type '$t')"; return
  fi
  for k in alwaysHuman moneySignals; do
    t="$(risk_jq -r --arg k "$k" '.promotion[$k] | type' "$config")"
    if [ "$t" = "null" ]; then echo "promotion.$k is absent"; return; fi
    if [ "$t" != "array" ]; then echo "promotion.$k is not an array"; return; fi
    n="$(risk_jq -r --arg k "$k" '.promotion[$k] | length' "$config")"
    if [ "$n" = "0" ]; then echo "promotion.$k is empty"; return; fi
  done
  t="$(risk_jq -r '.promotion.preconditions | type' "$config")"
  if [ "$t" != "object" ]; then echo "promotion.preconditions is absent"; return; fi
  for k in gateGreen reviewShip e2eEvidence; do
    t="$(risk_jq -r --arg k "$k" '.promotion.preconditions[$k] | type' "$config")"
    if [ "$t" = "null" ]; then echo "promotion.preconditions.$k is absent"; return; fi
    if [ "$t" != "boolean" ]; then echo "promotion.preconditions.$k is not a boolean"; return; fi
  done
  # Both twins compare maxChangedLines arithmetically; a float diverges across shells, and in bash the
  # compare errors out and SILENTLY SKIPS the size rule.
  t="$(risk_jq -r '.promotion.criteria.maxChangedLines | type' "$config")"
  if [ "$t" = "number" ]; then
    if [ "$(risk_jq -r '(.promotion.criteria.maxChangedLines | floor) == .promotion.criteria.maxChangedLines' "$config")" != "true" ]; then
      echo "promotion.criteria.maxChangedLines is not an integer"; return
    fi
  elif [ "$t" != "null" ]; then
    echo "promotion.criteria.maxChangedLines is not an integer (got type '$t')"; return
  fi
  echo ""
}

# The promotion decision — AUTO (auto-approve + auto-merge) or HUMAN (escalate, never merge).
# Fail-closed and ordered so the strongest refusals come first, BEFORE any config is consulted: the
# prod refusal does not read promotion.prod.autoMerge at all. The schema's `const: false` protects a
# repo that validates its config in CI; this line protects the ones that do not.
#   $1 config path  $2 env  $3 deterministicTier  $4 classifierTier
#   $5 gateGreen(1/0)  $6 reviewShip(1/0)  $7 e2eEvidence(1/0)  $8 reviewerConfigured(1/0)
# Takes the deterministic tier AND the classifier's verdict SEPARATELY and computes their max()
# itself (the escalate-only merge) so a caller cannot substitute a single hand-picked tier.
# Echoes "AUTO|reason" or "HUMAN|reason". Mirror of Get-PromotionDecision in risk.ps1.
promotion_decision() {
  local config="$1" envname="$2" dtier="$3" ctier="$4" gate="${5:-0}" ship="${6:-0}" e2e="${7:-0}" reviewer="${8:-0}"
  local t enabled pre_gate pre_ship pre_e2e threshold
  # TRIM, never `tr -d '[:space:]'`: deleting INTERIOR whitespace made "st aging" match staging in
  # bash while the PS twin's .Trim() correctly rejected it as an unknown environment.
  envname="$(printf '%s' "$envname" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # The escalate-only merge lives HERE, not in the caller: max() the two tiers so no caller can hand
  # a single pre-merged (lower) tier and bypass the classifier. Either input unknown/absent ranks
  # HIGH (risk_rank default, via risk_tier_max), so a garbage or omitted classifier tier fails CLOSED
  # to HUMAN. risk_tier_max already emits canonical LOW|MEDIUM|HIGH, mirroring the PS twin's
  # `Merge-RiskTier` — no rank round-trip needed.
  t="$(risk_tier_max "$dtier" "$ctier")"

  if [ "$envname" != "staging" ] && [ "$envname" != "prod" ]; then
    echo "HUMAN|unknown environment '$2'"; return
  fi
  if [ "$envname" = "prod" ]; then
    echo "HUMAN|prod promotion is always a human action"; return
  fi

  # Shape gate BEFORE any rule is trusted: a malformed block must refuse, never skip a rule.
  local shape_err; shape_err="$(promotion_config_shape "$config")"
  if [ -n "$shape_err" ]; then
    echo "HUMAN|promotion config not well-formed: $shape_err"; return
  fi

  enabled="$(risk_jq -r '.promotion.enabled // false' "$config")"
  if [ "$enabled" != "true" ]; then
    echo "HUMAN|promotion.enabled is not true (report-only)"; return
  fi

  # Preconditions gate the AUTO path but are not risk: a HIGH-risk change and an unreviewed change
  # both go to a human for different reasons, and the audit record must say which.
  pre_gate="$(risk_jq -r '.promotion.preconditions.gateGreen // false' "$config")"
  pre_ship="$(risk_jq -r '.promotion.preconditions.reviewShip // false' "$config")"
  pre_e2e="$(risk_jq -r '.promotion.preconditions.e2eEvidence // false' "$config")"
  if [ "$pre_gate" = "true" ] && [ "$gate" != "1" ]; then
    echo "HUMAN|precondition unmet: project gate is not green"; return
  fi
  if [ "$pre_ship" = "true" ] && [ "$ship" != "1" ]; then
    echo "HUMAN|precondition unmet: no fresh-context review SHIP for this range"; return
  fi
  if [ "$pre_e2e" = "true" ] && [ "$e2e" != "1" ]; then
    echo "HUMAN|precondition unmet: no end-to-end evidence for this range"; return
  fi

  threshold="$(risk_jq -r '.promotion.staging.autoMergeAtOrBelow // "" ' "$config")"
  threshold="$(printf '%s' "$threshold" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ "$threshold" != "low" ]; then
    echo "HUMAN|staging.autoMergeAtOrBelow is not \"low\" (report-only)"; return
  fi
  if [ "$t" != "LOW" ]; then
    echo "HUMAN|risk tier $t exceeds the staging auto-merge threshold"; return
  fi
  # Last gate before AUTO, and fail-closed by default (0): GitHub rejects self-approval, so the
  # auto-merge is only reachable when a SEPARATE reviewer identity is available to approve the PR. The
  # caller (/promote) computes this from promotion.reviewer.tokenEnv -> a non-empty token whose gh
  # identity differs from the PR author; it CANNOT be derived here (env + gh are the caller's), so an
  # omitted/unresolvable reviewer arrives as 0 and drops to HUMAN, never to the merge path.
  if [ "$reviewer" != "1" ]; then
    echo "HUMAN|no separate reviewer identity configured (promotion.reviewer.tokenEnv unset/empty or equals the PR author); GitHub rejects self-approval"; return
  fi
  echo "AUTO|LOW risk, all preconditions met, separate reviewer identity available, target staging"
}

# Collect the raw diff signals for a range. Thin by design — everything decision-shaped lives in the
# pure functions above so the self-tests can drive them without a git fixture. Writes the changed
# paths to $3 and the ADDED lines (leading '+' stripped, '+++' headers excluded — else every diff
# would "contain" its own paths and money-signal on them) to $4; echoes the changed-line count.
# Mirror of Get-DiffSignals in risk.ps1.
diff_signals() {  # $1 base  $2 head  $3 out-files-path  $4 out-added-path ; echoes changed lines
  local base="$1" head="${2:-HEAD}" out_files="$3" out_added="$4"
  git diff --name-only "$base" "$head" 2>/dev/null > "$out_files" || true
  git diff --unified=0 "$base" "$head" 2>/dev/null \
    | grep -E '^\+' | grep -vE '^\+\+\+' | sed -e 's/^+//' > "$out_added" || true
  # '-' in a numstat column means a binary file: no line count to add, but the file still counts.
  git diff --numstat "$base" "$head" 2>/dev/null \
    | awk -F'\t' '{ if ($1 ~ /^[0-9]+$/) s += $1; if ($2 ~ /^[0-9]+$/) s += $2 } END { print s + 0 }'
}
