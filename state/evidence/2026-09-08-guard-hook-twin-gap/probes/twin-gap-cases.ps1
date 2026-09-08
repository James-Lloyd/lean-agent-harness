param([Parameter(Mandatory)][string]$Hook)
$ErrorActionPreference = 'SilentlyContinue'
$psHost = (Get-Process -Id $PID).Path
function hookExit($cmd) {
  $payload = @{ tool_name='Bash'; tool_input=@{ command=$cmd } } | ConvertTo-Json -Compress
  $payload | & $psHost -NoProfile -ExecutionPolicy Bypass -File $Hook 1>$null 2>$null
  return $LASTEXITCODE
}
$RI = 'Remove' + '-Item'; $FV = 'Format' + '-Volume'; $CD = 'Clear' + '-Disk'; $CC = 'Clear' + '-Content'
$cases = @(
  "$RI -Recurse -Force .", "$RI -Force build", 'rmdir /s /q build', 'rd /s /q build',
  'del /s *.log', 'del /q *.log', "$FV -DriveLetter D", "$CD -Number 1", "$CC notes.txt",
  # flag-order forms (SF3) — must be DENIED
  'rmdir /q /s build', 'del /f /s *.log',
  # CONCATENATED and CHAINED switches — cmd.exe accepts these and they really delete. A
  # whitespace-only trailing boundary let them all through; these are the regression pins.
  'rd /s/q C:\temp\x', 'rmdir /s/q C:\temp\x', 'rd /q/s C:\temp\x', 'del /s/q C:\temp\*',
  'cmd /c rd /s/q C:\temp\x', 'rd C:\temp\x /s&&echo done',
  # controls — must be ALLOWED. The three /s-prefixed paths are SF1: POSIX roots, reachable here
  # because the PowerShell tool runs on POSIX via pwsh.
  'git status', 'npm test', "$RI stale.tmp",
  'rmdir /srv/cache', 'rmdir /sys/fs/cgroup/x', 'rd /storage/tmp',
  'echo the del /s switch is documented'
)
foreach ($c in $cases) {
  $rc = hookExit $c
  $verdict = if ($rc -eq 2) { 'DENIED' } else { 'ALLOWED' }
  '{0,-46} rc={1}  {2}' -f $c, $rc, $verdict
}
