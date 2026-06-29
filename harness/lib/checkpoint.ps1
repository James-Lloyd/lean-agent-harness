<#
  checkpoint.ps1 — git as the loop's undo button.
  Strategy: before each iteration we record HEAD. On a red gate we hard-reset back to it and clean
  untracked files, so a failed iteration never leaves a broken tree behind (the gnhf auto-rollback
  pattern). On green we commit and optionally tag for trivial revert.

  The checkpoint ref is also persisted to harness/.checkpoint so a crash mid-iteration leaves a record
  the next run can see. NOTE: rollback is `git reset --hard` + `git clean -fd`, which will discard any
  UNCOMMITTED changes in the tree. Do not edit the working tree while the loop runs; prefer running the
  loop on a dedicated branch or git worktree.
#>

$script:CheckpointRef = $null
$script:CheckpointFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.checkpoint'

function _Short([string]$ref) { if ($ref -and $ref.Length -ge 8) { $ref.Substring(0,8) } else { $ref } }

function Assert-CleanGitTree {
  if (-not (Test-Path (Join-Path $RepoRoot '.git'))) {
    throw "Not a git repo. The loop needs git as its checkpoint/rollback mechanism. Run: git init"
  }
  & git rev-parse --verify HEAD *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Repo has no commits yet. Make an initial commit before starting the loop (rollback needs a HEAD)."
  }
  $status = & git status --porcelain
  if ($status) {
    throw "Working tree is dirty. Commit or stash before starting the loop (it checkpoints via git)."
  }
}

function New-Checkpoint([string]$Label) {
  $script:CheckpointRef = (& git rev-parse HEAD).Trim()
  Set-Content -Path $script:CheckpointFile -Value $script:CheckpointRef -Encoding ascii -ErrorAction SilentlyContinue
  Write-Host "  ⎘ checkpoint @ $(_Short $script:CheckpointRef) ($Label)" -ForegroundColor DarkGray
}

function Restore-Checkpoint {
  $ref = $script:CheckpointRef
  if (-not $ref -and (Test-Path $script:CheckpointFile)) { $ref = (Get-Content $script:CheckpointFile -Raw).Trim() }
  if (-not $ref) { return }
  & git reset --hard $ref | Out-Null
  & git clean -fd | Out-Null     # remove untracked files the failed iteration created (gitignored files are spared)
  Write-Host "  ↩ restored to $(_Short $ref)" -ForegroundColor DarkGray
}

function Clear-Checkpoint {
  $script:CheckpointRef = $null
  Remove-Item $script:CheckpointFile -ErrorAction SilentlyContinue
}

function Commit-Iteration([int]$Index) {
  & git add -A | Out-Null
  $hasStaged = (& git diff --cached --name-only)
  if (-not $hasStaged) { Write-Host "  (no changes to commit)" -ForegroundColor DarkGray; return }
  $msg = "loop($Index): green iteration`n`nAutomated by harness/loop. Gate passed.`nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  & git commit -m $msg | Out-Null
  Write-Host "  ✔ committed iteration $Index" -ForegroundColor Green
}

function Tag-Iteration([int]$Index, [string]$RunId = '') {
  $tag = if ($RunId) { "loop-$RunId-$Index" } else { "loop-$Index" }   # namespaced so runs don't clobber each other
  & git tag -f $tag | Out-Null
  Write-Host "  🏷 tagged $tag" -ForegroundColor DarkGray
}
