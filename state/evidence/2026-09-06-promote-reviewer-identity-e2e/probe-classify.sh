#!/usr/bin/env bash
# Stage 1 of the /promote dogfood — the DECISION half, on real ranges of this repo.
#
# Runs the shipped engine path (lib/risk.sh: diff_signals -> deterministic_risk -> promotion_decision)
# over three REAL commit ranges and writes the §7 audit record for each. It does not touch GitHub and
# cannot merge anything: no `gh` call appears in this file.
#
# The shipped harness.config.json has promotion.enabled=false, which short-circuits every decision to
# HUMAN before the tier or the reviewer gate is ever consulted. To exercise those arms the probe
# builds a SHADOW config beside it (enabled=true) and passes that; the repo's own config is never
# written. That is the "shadow mode" docs/promotion.md §1 describes.
#
# Usage, from the repo root:
#   HARNESS_ENGINE=<repo>/plugin/engine bash state/evidence/<id>/probe-classify.sh
set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
ENGINE="${HARNESS_ENGINE:-$REPO/plugin/engine}"
EVID="$REPO/state/evidence/2026-09-06-promote-reviewer-identity-e2e"
RUNDIR="$REPO/harness/.runs/promote-$(date +%Y%m%dT%H%M%S)"
CFG="$REPO/harness/harness.config.json"
SHADOW="$EVID/probe-config.shadow.json"

mkdir -p "$EVID/risk" "$RUNDIR"
. "$ENGINE/lib/risk.sh"

# Shadow config: the shipped one with promotion.enabled flipped true. Nothing else changes, so the
# tiers, thresholds and money globs under test are the ones this repo actually ships.
jq '.promotion.enabled = true' "$CFG" > "$SHADOW"

echo "shipped   promotion.enabled = $(jq -r '.promotion.enabled' "$CFG")"
echo "shadow    promotion.enabled = $(jq -r '.promotion.enabled' "$SHADOW")"
echo "staging   branch            = $(jq -r '.promotion.staging.branch' "$CFG")"
echo

# classify <label> <base> <head> <reviewerConfigured 0|1>
classify() {
  local label="$1" base="$2" head="$3" reviewer="$4"
  local ff af lines det dtier dreason dec decision reason bsha hsha

  bsha="$(git rev-parse --short "$base")"; hsha="$(git rev-parse --short "$head")"
  ff="$(mktemp)"; af="$(mktemp)"
  lines="$(diff_signals "$base" "$head" "$ff" "$af")"
  det="$(deterministic_risk "$SHADOW" "$lines" "$ff" "$af")"
  dtier="${det%%|*}"; dreason="${det#*|}"

  # The classifier agent is a fresh-context judge and cannot run inside a probe script. Pass its tier
  # as the deterministic one: risk_tier_max() is escalate-only, so this is the NEUTRAL input — it can
  # never lower the deterministic tier, only leave it unchanged.
  dec="$(promotion_decision "$SHADOW" staging "$dtier" "$dtier" 1 1 1 "$reviewer")"
  decision="${dec%%|*}"; reason="${dec#*|}"

  printf '%-18s %s..%s  lines=%-5s tier=%-6s reviewer=%s  =>  %s\n' \
    "$label" "$bsha" "$hsha" "$lines" "$dtier" "$reviewer" "$decision"
  printf '    why: %s\n' "$dreason"
  printf '    decision reason: %s\n\n' "$reason"

  # NB: build the file array into a REAL temp file. `--slurpfile x <(...)` fails under Git Bash on
  # Windows — jq cannot open the /proc/<pid>/fd path the process substitution hands it.
  local fj; fj="$(mktemp)"
  jq -R . < "$ff" | jq -s . > "$fj"

  jq -n --arg range "$bsha..$hsha" --arg label "$label" \
        --arg dt "$dtier" --arg dr "$dreason" \
        --arg dec "$decision" --arg reason "$reason" \
        --argjson rev "$reviewer" --argjson lines "${lines:-0}" \
        --slurpfile files "$fj" '
    { label: $label, range: $range, environment: "staging",
      deterministicTier: $dt, deterministicReasons: [$dr],
      classifierTier: $dt,
      classifierProof: "not run in this probe; passed the deterministic tier as the neutral input to the escalate-only max()",
      finalTier: $dt,
      preconditions: { gateGreen: true, reviewShip: true, e2eEvidence: true },
      reviewerConfigured: ($rev == 1),
      decision: $dec, reason: $reason,
      changedFiles: $files[0], changedLines: $lines,
      outcome: null }' > "$EVID/risk/risk-$label.json"

  printf '{"iter":0,"result":"risk","tier":"%s","decision":"%s","env":"staging","path":"claude","usedFallback":false}\n' \
    "$dtier" "$decision" >> "$RUNDIR/ledger.jsonl"

  rm -f "$ff" "$af" "$fj"
}

# --- the three tiers the S3 task asks for, on real ranges of this repo ------------------------
# LOW  : a real merged docs-only commit (AGENT_NOTES.md, 5 added lines). Note how narrow this is on
#        THIS repo: `RISK_SELF_GOVERN_GLOBS` pins any change to the harness's own policy, guardrail
#        or CI files to HIGH, so almost every commit here is HIGH by construction — including the
#        batch this evidence belongs to (see high-thisbatch below). A LOW range on a self-governing
#        repo has to be one that touches none of its own controls.
classify low-docs          553b9b0^ 553b9b0 1
# MEDIUM: a range whose only trip is SIZE. Same docs-only shape, taken wide enough to cross
#        maxChangedLines (1000) without touching a governed path or a money word.
classify medium-size       85b8965^ 85b8965 1
# HIGH  : the commit that introduced the promotion config — its ADDED lines carry the money
#        vocabulary (price, refund, payout, invoice, tax, ...), so moneySignals pins it HIGH.
classify high-money        7a1ebe6^ 7a1ebe6 1

# --- the reviewer gate: the SAME LOW range, reviewer boolean flipped ---------------------------
# This pair is the point of the whole batch. Identical range, identical tiers, identical
# preconditions — only the reviewer identity differs, and only one of them may merge.
classify low-noreviewer    553b9b0^ 553b9b0 0

# --- and this batch itself, classified honestly -----------------------------------------------
classify high-thisbatch    "$(git merge-base HEAD main)" HEAD 1

cp "$RUNDIR/ledger.jsonl" "$EVID/ledger.jsonl"
echo "ledger rows written to <repo>/harness/.runs/$(basename "$RUNDIR")/ledger.jsonl (copied to the evidence dir):"
cat "$EVID/ledger.jsonl"
