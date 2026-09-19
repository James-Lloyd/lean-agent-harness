# Harness 0.5.3 auto-loop and wrapper evidence

## What was proved

- `focused-powershell.txt` and `focused-bash.txt`: 7/0 each. With `maxIterations=3` and
  `commitOnGreen=false`, the real loop invokes its stub model once, leaves the first green edit
  uncommitted, records one green ledger row, and prints the truthful no-commit warning. The same probe
  verifies the commit-enabled warning and proves a 0.5.3 wrapper beats a newer-timestamp 0.5.1 cache.
- `mutation/result.json`: controls pass; deleting the safe stop independently from each engine twin
  makes both focused tests fail because iteration two restores the shared HEAD and erases iteration
  one's accepted edit. The four raw run logs are beside the result.
- `package-validation.txt`: all three manifests agree on 0.5.3 and the shared dual-host package,
  hooks, skills, and six wrapper sources are internally consistent.
- `root-gate.txt`: the complete configured gate passed both twins after these changes.

Consumer migration and installed-cache evidence is added here after the source release is installed.
