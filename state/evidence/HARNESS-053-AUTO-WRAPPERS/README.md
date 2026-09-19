# Harness 0.5.3 auto-loop and wrapper evidence

## What was proved

- `focused-powershell.txt` and `focused-bash.txt`: 9/0 each. With `maxIterations=3` and
  `commitOnGreen=false`, the real loop invokes its stub model once, leaves the first green edit
  uncommitted, records one green ledger row, creates no false tag at the unchanged HEAD, and prints the
  truthful no-commit warning. The same probe verifies the commit-enabled warning and proves semantic
  version ordering globally across the Codex and Claude cache roots in both directions.
- `mutation/result.json`: controls pass; deleting the safe stop independently from each engine twin
  makes both focused tests fail because iteration two restores the shared HEAD and erases iteration
  one's accepted edit. The four raw run logs are beside the result.
- `package-validation.txt`: all three manifests agree on 0.5.3 and the shared dual-host package,
  hooks, skills, and six wrapper sources are internally consistent.
- `root-gate.txt`: the complete configured gate passed both twins after these changes.
- `review-fixes.txt`: both migration twins pass 44/0 with all six wrappers, and the independent
  Codex-timeout mutation probe passes controls, rejects both mutants, and validates 0.5.3.

Consumer migration and installed-cache evidence is added here after the source release is installed.
