<#
  checkpoint.ps1 — git as the loop's undo button.
  Strategy: before each iteration we record HEAD. On a red gate we hard-reset back to it and clean
  untracked files, so a failed iteration never leaves a broken tree behind (the gnhf auto-rollback
  pattern). On green we commit and optionally tag (loop-N) for trivial revert.
#>

$script:CheckpointRef = $null

function Assert-CleanGitTree {
  if (-not (Test-Path (Join-Path $RepoRoot '.git'))) {
    throw "Not a git repo. The loop needs git as its checkpoint/rollback mechanism. Run: git init"
  }
  $status = & git status --porcelain
  if ($status) {
    throw "Working tree is dirty. Commit or stash before starting the loop (it checkpoints via git)."
  }
}

function New-Checkpoint([string]$Label) {
  $script:CheckpointRef = (& git rev-parse HEAD).Trim()
  Write-Host "  ⎘ checkpoint @ $($script:CheckpointRef.Substring(0,8)) ($Label)" -ForegroundColor DarkGray
}

function Restore-Checkpoint {
  if (-not $script:CheckpointRef) { return }
  & git reset --hard $script:CheckpointRef | Out-Null
  & git clean -fd | Out-Null     # remove untracked files the failed iteration created
  Write-Host "  ↩ restored to $($script:CheckpointRef.Substring(0,8))" -ForegroundColor DarkGray
}

function Clear-Checkpoint { $script:CheckpointRef = $null }

function Commit-Iteration([int]$Index) {
  & git add -A | Out-Null
  $hasStaged = (& git diff --cached --name-only)
  if (-not $hasStaged) { Write-Host "  (no changes to commit)" -ForegroundColor DarkGray; return }
  $msg = "loop($Index): green iteration`n`nAutomated by harness/loop. Gate passed.`nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  & git commit -m $msg | Out-Null
  Write-Host "  ✔ committed iteration $Index" -ForegroundColor Green
}

function Tag-Iteration([int]$Index) {
  $tag = "loop-$Index"
  & git tag -f $tag | Out-Null
  Write-Host "  🏷 tagged $tag" -ForegroundColor DarkGray
}
