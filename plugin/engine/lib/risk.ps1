<#
  risk.ps1 — risk classification for gated promotion (staging / prod).

  What this file is for: deciding how much human scrutiny a already-green, already-reviewed diff
  needs before it is merged onward. It does NOT decide whether the change is correct — the gate and
  the fresh-context reviewer already did that. It decides whether a human must look.

  Three invariants, all enforced in CODE here rather than trusted from a prompt:

   1. ESCALATE-ONLY. Every stage may RAISE a tier and none may lower it (Merge-RiskTier is a max()
      over LOW<MEDIUM<HIGH). The deterministic rules below run first; the risk-classifier agent runs
      second and is merged, never substituted. A change's author — human or agent — cannot classify
      its own change as low-risk.
   2. FAIL-CLOSED. Anything unparseable, unknown, absent, or empty resolves to HIGH / HUMAN. An
      unrecognized tier string is HIGH. An empty diff is HIGH. A missing verdict line is HIGH.
   3. PROD IS NEVER AUTOMATED. Get-PromotionDecision refuses a prod AUTO before it reads any config
      at all. The schema also pins promotion.prod.autoMerge to const false, but that only helps a
      repo that validates its config — this check helps every repo.

  Mirror of risk.sh. Twin rule applies: a change lands in both or not at all.
#>

# StrictMode-safe property access (a promotion block may legitimately omit keys, and /harness-prune
# may trim config). Named distinctly from gate.ps1's Get-Prop so sourcing both is never a clash.
function Get-RiskProp($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($p) { return $p.Value } else { return $null }
}

# Type/shape PREDICATES over a property. These return a bool or an int, never the value itself, and
# that is the whole point: PowerShell UNROLLS an array returned from a function, so a single-element
# `alwaysHuman: ["**/payments/**"]` arrives at the caller as a bare String and a `-is [Array]` test
# rejects a perfectly legal config. (`return ,$value` is the usual dodge but it survives assignment
# and NOT an inline `@(f ...)`; an ArrayList round-trip does not help either, because the unroll
# happens on the function's OUTPUT. Never returning the value sidesteps all of it.)
function Test-RiskPropPresent($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  $p = $obj.PSObject.Properties[$name]
  return ($p -and $null -ne $p.Value)
}
function Test-RiskPropIsArray($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  $p = $obj.PSObject.Properties[$name]
  if (-not $p) { return $false }
  return ($p.Value -is [System.Collections.IEnumerable] -and $p.Value -isnot [string])
}
function Get-RiskPropCount($obj, [string]$name) {
  if ($null -eq $obj) { return 0 }
  $p = $obj.PSObject.Properties[$name]
  if (-not $p -or $null -eq $p.Value) { return 0 }
  return @($p.Value).Count
}
# Integral-VALUE test, deliberately not a concrete .NET TYPE test. ConvertFrom-Json returns Int32
# under Windows PowerShell 5.1 and Int64 under pwsh, so `-is [int]` rejected a perfectly valid
# `maxChangedLines: 1000` on pwsh only -- caught by CI, which runs both hosts. Mirrors the sh twin,
# which asks jq whether `floor == value` rather than inspecting a type name.
function Test-RiskPropIsInteger($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  $p = $obj.PSObject.Properties[$name]
  if (-not $p -or $null -eq $p.Value) { return $false }
  $v = $p.Value
  if ($v -is [bool] -or $v -is [string]) { return $false }
  try { $d = [double]$v } catch { return $false }
  return ([Math]::Floor($d) -eq $d)
}
function Test-RiskPropIsBool($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  $p = $obj.PSObject.Properties[$name]
  if (-not $p) { return $false }
  return ($p.Value -is [bool])
}

# Paths whose change governs the promotion policy ITSELF, or the guardrails the policy leans on.
# HARDCODED, deliberately not config-driven: if the escalation list for "edits to the escalation
# list" were itself in config, one edit could disarm the whole mechanism and then auto-merge itself.
# Ona's governance point ("changes to the evaluation logic, criteria, or review prompt require
# explicit approval") expressed as code. Repo-relative, forward slashes.
$script:RiskSelfGovernGlobs = @(
  'specs/**',                          # the immutable contract
  'harness/harness.config.json',       # the gate, the routing, and this policy
  '.claude/settings.json',             # permissions + guard hooks
  '.claude/hooks/**',
  '.github/workflows/**',              # CI can bypass every other gate
  'plugin/hooks/**',
  'plugin/engine/lib/risk.ps1',
  'plugin/engine/lib/risk.sh',
  'plugin/agents/risk-classifier.md',
  'plugin/commands/promote.md',
  'plugin/skills/risk-tiering/**'
)

# Translate a path glob to an anchored regex, with the SAME semantics on both runners (PowerShell's
# -like has no `**`, and bash `case` globs cross `/` differently — so neither native mechanism is
# used). Rules: `**/` spans zero or more whole segments, `**` spans anything, `*` and `?` never
# cross `/`. Matching is case-insensitive and whole-path.
# Expansion goes through placeholders because the replacements themselves contain `*` and `/` — a
# naive sequential replace would re-process its own output. Mirror of glob_to_regex in risk.sh.
function Convert-GlobToRegex([string]$Glob) {
  # NB: `[char]1`, not a `u{0001}` escape — the latter is PowerShell 6+ and this engine's primary
  # Windows runtime is 5.1, where it is a parse error for the whole file.
  $ph = [string][char]1
  $g = ("$Glob").Replace('\', '/')
  $g = $g -replace '([\\.+()\[\]{}^$|])', '\$1'   # escape regex metachars, but NOT * or ?
  $g = $g.Replace('**/', "${ph}A")                # order matters: longest token first
  $g = $g.Replace('**',  "${ph}B")
  $g = $g.Replace('*',   "${ph}C")
  $g = $g.Replace('?',   "${ph}D")
  $g = $g.Replace("${ph}A", '(.*/)?').Replace("${ph}B", '.*')
  $g = $g.Replace("${ph}C", '[^/]*').Replace("${ph}D", '[^/]')
  return '^' + $g + '$'
}

# Compile a whole glob SET to ONE alternation regex. Compiling per-glob-per-file instead is O(files x
# globs): on a real 57-file promotion diff against the shipped criteria that is ~2800 compilations,
# and in the sh twin (where each one is a sed + grep fork) it took MINUTES and made /promote unusable.
# Compile once per rule group, match in one pass. Mirror of globs_union_regex in risk.sh.
function Get-GlobUnionRegex($Globs) {
  $parts = @(@($Globs) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
             ForEach-Object { Convert-GlobToRegex ([string]$_) })
  if ($parts.Count -eq 0) { return '' }
  return ($parts -join '|')
}

# Normalize a repo-relative path for matching. Mirror of normalize_path in risk.sh.
function ConvertTo-NormalizedPath([string]$Path) {
  # Strip a leading './' only. NOT TrimStart('./') — that trims the CHARACTER SET '.' and '/', which
  # would turn '.github/workflows/x.yml' into 'github/workflows/x.yml' and silently unmatch it.
  $p = ("$Path").Replace('\', '/')
  while ($p.StartsWith('./')) { $p = $p.Substring(2) }
  return $p
}

# Does a repo-relative path match ANY of the globs? Mirror of path_matches_any in risk.sh.
function Test-PathMatchesAny([string]$Path, $Globs) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $rx = Get-GlobUnionRegex $Globs
  if ([string]::IsNullOrEmpty($rx)) { return $false }
  return [regex]::IsMatch((ConvertTo-NormalizedPath $Path), $rx, 'IgnoreCase')
}

# Every path in $Paths matching ANY glob in $Globs — one compiled regex for the whole group. This is
# the hot path that keeps /promote fast on a real diff. Mirror of paths_matching in risk.sh.
function Select-MatchingPath($Paths, $Globs) {
  $rx = Get-GlobUnionRegex $Globs
  if ([string]::IsNullOrEmpty($rx)) { return @() }
  $re = New-Object System.Text.RegularExpressions.Regex($rx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  return @(@($Paths) | Where-Object { $re.IsMatch((ConvertTo-NormalizedPath ([string]$_))) })
}

# Rank a tier. Anything unrecognized ranks as HIGH — an unknown tier is not a low one.
function Get-RiskRank([string]$Tier) {
  switch (("$Tier").Trim().ToUpperInvariant()) {
    'LOW'    { return 0 }
    'MEDIUM' { return 1 }
    'HIGH'   { return 2 }
    default  { return 2 }
  }
}

# The escalate-only ratchet, in code: the merged tier is the HIGHER of the two. This is what makes
# "the agent may confirm or raise, never lower" a property of the system rather than a promise in a
# prompt. Mirror of risk_tier_max in risk.sh.
function Merge-RiskTier([string]$A, [string]$B) {
  $rank = [Math]::Max((Get-RiskRank $A), (Get-RiskRank $B))
  return @('LOW', 'MEDIUM', 'HIGH')[$rank]
}

# Parse the risk-classifier agent's verdict from its output: LOW | MEDIUM | HIGH. Mirrors
# Get-ReviewVerdict's fail-closed last-line rule — only the LAST line STARTING with RISK: counts, so
# a mid-reasoning "RISK: LOW would be wrong here" cannot decide the outcome. Any other outcome (no
# text, no RISK: line, an unrecognized token) is HIGH, not NONE: unlike a review verdict there is no
# neutral value, and the safe direction is more human attention, not less.
# Mirror of risk_verdict in risk.sh.
# CASE-SENSITIVE (-cmatch, never -match). PowerShell's -match is case-INSENSITIVE by default while
# the sh twin's grep -E is not, and that divergence LOWERS tiers: the classifier is explicitly invited
# to add a prose note for the human, so an output ending
#     RISK: HIGH
#     risk: low blast radius here, the deterministic rules look over-escalated
# took the prose line as the last verdict and returned LOW on PowerShell and HIGH on bash. The
# contract's verdict form is uppercase; anything else is prose and must fail closed to HIGH.
function Get-RiskVerdict([string]$Text) {
  if (-not $Text) { return 'HIGH' }
  $line = @($Text -split "`r?`n" | Where-Object { $_ -cmatch '^\s*RISK:' }) | Select-Object -Last 1
  if (-not $line) { return 'HIGH' }
  if ($line -cmatch '^\s*RISK:\s*LOW(\s|$)')    { return 'LOW' }
  if ($line -cmatch '^\s*RISK:\s*MEDIUM(\s|$)') { return 'MEDIUM' }
  return 'HIGH'
}

# Money-signal match against diff TEXT: the term must start a word, with NO constraint on what
# follows. NOT \b — BSD grep in the sh twin has no \b and the twins must agree character for
# character, so both emulate the boundary with an explicit class.
#
# Leading boundary only, and `_` counts as a separator (class is [^A-Za-z0-9], not [^A-Za-z0-9_]).
# That is deliberate, and an earlier trailing-boundary version was WRONG in the dangerous direction:
# it missed `tax_rate`, `taxes`, `prices`, `amounts` — inflected and snake_case forms are most of how
# money words actually appear in code, so the rule silently passed real money diffs as LOW.
# The cost is a false positive on a word that merely STARTS with a money term (`taxonomy`, `balancer`).
# That is the correct trade: a false HIGH costs one human glance, a false LOW auto-merges a money bug.
# A term mid-word (`syntax` for `tax`) still does not fire.
function Test-MoneySignal([string]$Text, [string]$Term) {
  if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrWhiteSpace($Term)) { return $false }
  $t = [regex]::Escape($Term.Trim())
  $opts = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Multiline'
  return [regex]::IsMatch($Text, "(^|[^A-Za-z0-9])$t", $opts)
}

<#
  The deterministic classifier — stage 1, and the only stage that can produce LOW.

  Every criterion is computed FROM THE DIFF, so it cannot be talked around. Each rule can only
  raise the tier; the order below is therefore irrelevant to the result, only to the reason list.

  -Config       the whole harness config object (reads .promotion)
  -Files        repo-relative paths changed in the range
  -ChangedLines additions + deletions across the range
  -AddedText    the ADDED lines of the diff (money signals are content, not paths)

  Returns [pscustomobject]@{ Tier = 'LOW'|'MEDIUM'|'HIGH'; Reasons = string[] }.
  Mirror of deterministic_risk in risk.sh.
#>
function Get-DeterministicRisk {
  param($Config, $Files = @(), [int]$ChangedLines = 0, [string]$AddedText = '')
  $p        = Get-RiskProp $Config 'promotion'
  $files    = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $tier     = 'LOW'
  $reasons  = New-Object System.Collections.Generic.List[string]

  # Fail-closed: nothing to classify is not "low risk", it is a caller bug or a resolved-wrong range.
  if ($files.Count -eq 0 -and $ChangedLines -le 0) {
    # ASCII-only inside emitted STRINGS (comments are fine): PS 5.1 reads a BOM-less .ps1 as ANSI, so
    # a non-ASCII literal reaches the audit record and the PR comment as mojibake.
    return [pscustomobject]@{ Tier = 'HIGH'; Reasons = @('empty diff - nothing to classify (fail-closed)') }
  }

  # One compiled regex per rule group over the whole file list — never per (file, glob) pair.
  foreach ($f in (Select-MatchingPath $files $script:RiskSelfGovernGlobs)) {
    $tier = Merge-RiskTier $tier 'HIGH'; $reasons.Add("self-governance: $f (policy, guardrails, or CI)")
  }
  foreach ($f in (Select-MatchingPath $files (Get-RiskProp $p 'alwaysHuman'))) {
    $tier = Merge-RiskTier $tier 'HIGH'; $reasons.Add("alwaysHuman path: $f")
  }
  foreach ($term in @(Get-RiskProp $p 'moneySignals')) {
    if (Test-MoneySignal $AddedText ([string]$term)) {
      $tier = Merge-RiskTier $tier 'HIGH'; $reasons.Add("money signal '$term' in added lines")
    }
  }

  $criteria = Get-RiskProp $p 'criteria'
  $maxLines = Get-RiskProp $criteria 'maxChangedLines'
  if ($null -ne $maxLines -and $ChangedLines -ge [int]$maxLines) {
    $tier = Merge-RiskTier $tier 'MEDIUM'; $reasons.Add("$ChangedLines changed lines (limit $maxLines)")
  }
  $escalate = Get-RiskProp $criteria 'escalatePaths'
  if ($null -ne $escalate) {
    foreach ($cat in $escalate.PSObject.Properties) {
      # First match only: the category is the finding, not each file in it.
      $hit = @(Select-MatchingPath $files $cat.Value) | Select-Object -First 1
      if ($hit) { $tier = Merge-RiskTier $tier 'MEDIUM'; $reasons.Add("$($cat.Name): $hit") }
    }
  }

  if ($reasons.Count -eq 0) { $reasons.Add('no escalation criterion tripped') }
  return [pscustomobject]@{ Tier = $tier; Reasons = @($reasons) }
}

<#
  The promotion decision — AUTO (auto-approve + auto-merge) or HUMAN (escalate, never merge).

  Fail-closed and ordered so the strongest refusals are evaluated first, BEFORE any config is
  consulted. In particular the prod refusal does not read promotion.prod.autoMerge at all: the
  schema's `const: false` protects repos that validate their config in CI, and this line protects
  the ones that do not.

  Returns [pscustomobject]@{ Decision = 'AUTO'|'HUMAN'; Reason = string }.
  Mirror of promotion_decision in risk.sh.
#>
<#
  Shape-validate the promotion block before ANY of it is trusted.

  Without this, every degenerate shape SKIPS a rule instead of escalating — i.e. the block fails
  OPEN, which contradicts this file's own fail-closed contract. Three real cases, all of which
  reached AUTO before this gate existed:
   - `preconditions` absent entirely (schema-valid; /harness-prune may trim it) => a red gate, no
     review SHIP and no e2e evidence all passed, and the audit string still read "all preconditions
     met";
   - `alwaysHuman` / `moneySignals` written as a scalar instead of an array (a plausible hand-edit)
     => the whole money rule silently evaluated to "no match", so a payments diff classified LOW;
   - `enabled: "false"` as a STRING => PowerShell coerces the non-empty string to $true, so the
     master switch read as ON.

  Anything not exactly right returns a reason and the caller refuses. Mirror of
  promotion_config_shape in risk.sh.
#>
function Test-PromotionConfigShape($Promotion) {
  if ($null -eq $Promotion) { return 'promotion block is absent' }

  # Strictly boolean: a stringly-typed 'false'/'no'/'off' must never read as ON.
  if (-not (Test-RiskPropIsBool $Promotion 'enabled')) {
    return "promotion.enabled is not a boolean (got '$(Get-RiskProp $Promotion 'enabled')')"
  }

  foreach ($key in @('alwaysHuman', 'moneySignals')) {
    if (-not (Test-RiskPropPresent $Promotion $key)) { return "promotion.$key is absent" }
    if (-not (Test-RiskPropIsArray $Promotion $key)) { return "promotion.$key is not an array" }
    if ((Get-RiskPropCount $Promotion $key) -eq 0)   { return "promotion.$key is empty" }
  }

  $pre = Get-RiskProp $Promotion 'preconditions'
  if ($null -eq $pre) { return 'promotion.preconditions is absent' }
  foreach ($key in @('gateGreen', 'reviewShip', 'e2eEvidence')) {
    if (-not (Test-RiskPropPresent $pre $key)) { return "promotion.preconditions.$key is absent" }
    if (-not (Test-RiskPropIsBool $pre $key))  { return "promotion.preconditions.$key is not a boolean" }
  }

  $criteria = Get-RiskProp $Promotion 'criteria'
  if ((Test-RiskPropPresent $criteria 'maxChangedLines') -and -not (Test-RiskPropIsInteger $criteria 'maxChangedLines')) {
    # Both twins compare it arithmetically; a fractional value diverges across shells (and in bash the
    # compare errors out and silently SKIPS the size rule).
    return "promotion.criteria.maxChangedLines is not an integer (got '$(Get-RiskProp $criteria 'maxChangedLines')')"
  }
  return ''   # well-formed
}

function Get-PromotionDecision {
  param($Config, [string]$Environment, [string]$Tier,
        [bool]$GateGreen = $false, [bool]$ReviewShip = $false, [bool]$E2EEvidence = $false)
  # Named $envName, not $env: `$env` reads as the environment-variable drive in PowerShell and the
  # shadowing is a trap for the next reader.
  $envName = ("$Environment").Trim().ToLowerInvariant()
  $t       = @('LOW','MEDIUM','HIGH')[(Get-RiskRank $Tier)]

  if ($envName -ne 'staging' -and $envName -ne 'prod') {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = "unknown environment '$Environment'" }
  }
  # Unconditional, config-independent, and first: prod promotion is a human action, always.
  if ($envName -eq 'prod') {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = 'prod promotion is always a human action' }
  }

  $p = Get-RiskProp $Config 'promotion'

  # Shape gate BEFORE any rule is trusted: a malformed block must refuse, never skip a rule.
  $shapeErr = Test-PromotionConfigShape $p
  if ($shapeErr) {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = "promotion config not well-formed: $shapeErr" }
  }

  if ($true -ne (Get-RiskProp $p 'enabled')) {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = 'promotion.enabled is not true (report-only)' }
  }

  # Preconditions gate the AUTO path but are not risk: a HIGH-risk change and an unreviewed change
  # both go to a human, for different reasons, and the audit record must say which.
  $pre = Get-RiskProp $p 'preconditions'
  if ($true -eq (Get-RiskProp $pre 'gateGreen')   -and -not $GateGreen)   {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = 'precondition unmet: project gate is not green' }
  }
  if ($true -eq (Get-RiskProp $pre 'reviewShip')  -and -not $ReviewShip)  {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = 'precondition unmet: no fresh-context review SHIP for this range' }
  }
  if ($true -eq (Get-RiskProp $pre 'e2eEvidence') -and -not $E2EEvidence) {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = 'precondition unmet: no end-to-end evidence for this range' }
  }

  $threshold = Get-RiskProp (Get-RiskProp $p 'staging') 'autoMergeAtOrBelow'
  if (("$threshold").Trim().ToLowerInvariant() -ne 'low') {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = 'staging.autoMergeAtOrBelow is not "low" (report-only)' }
  }
  if ($t -ne 'LOW') {
    return [pscustomobject]@{ Decision = 'HUMAN'; Reason = "risk tier $t exceeds the staging auto-merge threshold" }
  }
  return [pscustomobject]@{ Decision = 'AUTO'; Reason = 'LOW risk, all preconditions met, target staging' }
}

<#
  Collect the raw diff signals for a range. Thin by design — everything decision-shaped lives in the
  pure functions above so the self-tests can drive them without a git fixture.

  Returns [pscustomobject]@{ Files = string[]; ChangedLines = int; AddedText = string }.
  AddedText holds only ADDED lines with the leading '+' stripped, and excludes the '+++' file
  headers (else every diff would "contain" its own paths and money-signal on them).
  Mirror of diff_signals in risk.sh.
#>
function Get-DiffSignals([string]$BaseRef, [string]$HeadRef = 'HEAD') {
  $files = @(& git diff --name-only "$BaseRef" "$HeadRef" 2>$null | Where-Object { $_ })
  $lines = 0
  foreach ($row in @(& git diff --numstat "$BaseRef" "$HeadRef" 2>$null)) {
    $cols = "$row" -split "`t"
    if ($cols.Count -ge 2) {
      # '-' in a numstat column means a binary file: no line count to add, but the file still counts.
      if ($cols[0] -match '^\d+$') { $lines += [int]$cols[0] }
      if ($cols[1] -match '^\d+$') { $lines += [int]$cols[1] }
    }
  }
  $added = @(& git diff --unified=0 "$BaseRef" "$HeadRef" 2>$null |
             Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' } |
             ForEach-Object { $_.Substring(1) })
  return [pscustomobject]@{ Files = $files; ChangedLines = $lines; AddedText = ($added -join "`n") }
}
