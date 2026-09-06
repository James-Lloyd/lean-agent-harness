#!/usr/bin/env bash
# Stage 2 — the same engine path, on a throwaway repo shaped like a real CONSUMER project.
#
# Why this exists alongside probe-classify.sh: this harness repo self-governs, so
# RISK_SELF_GOVERN_GLOBS pins nearly every range in it to HIGH, and its promotion docs quote the money
# vocabulary in prose. That makes it a poor place to demonstrate a clean MEDIUM, or a money HIGH that
# is really about money rather than about editing the policy. So: a real git repo, real commits, real
# ranges, classified by the SHIPPED config and the SHIPPED lib — just not this one's history.
#
# Nothing here touches GitHub, and the temp repo is deleted at the end.
set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
ENGINE="${HARNESS_ENGINE:-$REPO/plugin/engine}"
EVID="$REPO/state/evidence/2026-09-06-promote-reviewer-identity-e2e"
SHADOW="$EVID/probe-config.shadow.json"
. "$ENGINE/lib/risk.sh"

TMP="$(mktemp -d)"
cd "$TMP" || exit 1
git init -q .
git config user.email "probe@example.invalid"
git config user.name  "Promotion Probe"

mkdir -p docs src/util db/migrations src/checkout
printf 'consumer app\n'                  > README.md
printf '# guide\n'                       > docs/guide.md
printf 'export const id = 1\n'           > src/util/id.ts
git add -A; git commit -qm "base: scaffold"
BASE="$(git rev-parse HEAD)"

# LOW — a docs-only change: no governed path, no money word, well under the size limit.
printf '# guide\n\nA second paragraph.\n' > docs/guide.md
git add -A; git commit -qm "docs: expand the guide"
LOW_C="$(git rev-parse HEAD)"

# MEDIUM — a migration. escalatePaths.migrations matches `**/migrations/**`; nothing raises it further.
printf 'CREATE INDEX idx_user_email ON users (email);\n' > db/migrations/002_add_index.sql
git add -A; git commit -qm "db: add an index migration"
MED_C="$(git rev-parse HEAD)"

# HIGH — a checkout change: the path is in alwaysHuman AND the added lines carry money vocabulary.
cat > src/checkout/pricing.ts <<'TS'
export function totalPrice(amount: number, taxRate: number): number {
  const tax = amount * taxRate
  return amount + tax
}
export function refundAmount(charge: number): number { return charge }
TS
git add -A; git commit -qm "checkout: pricing helpers"
HIGH_C="$(git rev-parse HEAD)"

# HIGH by CONTENT alone — a money constant in an ordinary util path. This is the case path globs miss,
# and the one the SIGPIPE defect silently disabled on every real-sized diff until 2026-09-06.
printf 'export const price = 1999\n' >> src/util/id.ts
git add -A; git commit -qm "util: inline a price constant"
CONTENT_C="$(git rev-parse HEAD)"

show() {  # $1 label  $2 base  $3 head  $4 expected tier  $5 record slug
  local label="$1" base="$2" head="$3" want="$4" slug="$5" ff af fj lines det tier reasons dec
  ff="$(mktemp)"; af="$(mktemp)"; fj="$(mktemp)"
  lines="$(diff_signals "$base" "$head" "$ff" "$af")"
  det="$(deterministic_risk "$SHADOW" "$lines" "$ff" "$af")"
  tier="${det%%|*}"; reasons="${det#*|}"
  dec="$(promotion_decision "$SHADOW" staging "$tier" "$tier" 1 1 1 1)"
  printf '%-22s files=%-32s tier=%-6s (expected %-6s) %s\n' \
    "$label" "$(tr '\n' ',' < "$ff")" "$tier" "$want" "$([ "$tier" = "$want" ] && echo OK || echo MISMATCH)"
  printf '    why: %s\n' "$reasons"
  printf '    decision: %s\n\n' "$dec"

  # The §7 audit record, same shape /promote writes. `--slurpfile` needs a real file: process
  # substitution hands jq a /proc/<pid>/fd path it cannot open under Git Bash on Windows.
  jq -R . < "$ff" | jq -s . > "$fj"
  jq -n --arg label "$label" --arg range "$(git rev-parse --short "$base")..$(git rev-parse --short "$head")" \
        --arg dt "$tier" --arg dr "$reasons" --arg dec "${dec%%|*}" --arg reason "${dec#*|}" \
        --argjson lines "${lines:-0}" --slurpfile files "$fj" '
    { label: $label, repo: "throwaway consumer-shaped repo (see probe-consumer.sh)",
      range: $range, environment: "staging",
      deterministicTier: $dt, deterministicReasons: [$dr],
      classifierTier: $dt,
      classifierProof: "not run in this probe; passed the deterministic tier as the neutral input to the escalate-only max()",
      finalTier: $dt,
      preconditions: { gateGreen: true, reviewShip: true, e2eEvidence: true },
      reviewerConfigured: true,
      decision: $dec, reason: $reason,
      changedFiles: $files[0], changedLines: $lines,
      outcome: null }' > "$EVID/risk/risk-consumer-$slug.json"

  printf '{"iter":0,"result":"risk","tier":"%s","decision":"%s","env":"staging","path":"claude","usedFallback":false}\n' \
    "$tier" "${dec%%|*}" >> "$EVID/ledger-consumer.jsonl"
  rm -f "$ff" "$af" "$fj"
}

echo "throwaway consumer repo, classified by the shipped lib + shipped globs"
echo
show "LOW docs-only"        "$BASE"      "$LOW_C"     LOW    low
show "MEDIUM migration"     "$LOW_C"     "$MED_C"     MEDIUM medium
show "HIGH checkout+money"  "$MED_C"     "$HIGH_C"    HIGH   high-money-path
show "HIGH money-in-util"   "$HIGH_C"    "$CONTENT_C" HIGH   high-money-content

echo "ledger rows:"
cat "$EVID/ledger-consumer.jsonl"

cd /
rm -rf "$TMP"
