# Harness 0.5.3 auto-loop and wrapper evidence

## What was proved

- `focused-powershell.txt` and `focused-bash.txt`: 13/0 each. With `maxIterations=3` and
  `commitOnGreen=false`, the real loop invokes its stub model once, leaves the first green edit
  uncommitted, records one green ledger row, creates no false tag at the unchanged HEAD, and prints the
  truthful no-commit warning. The same probe verifies the commit-enabled warning and proves semantic
  version ordering globally across the Codex and Claude cache roots in both directions. The added
  Codex-route controls prove the banner names the real workspace-write Codex CLI path and contains no
  false `claude -p` invocation. The final twinned assertions run every one of the six wrapper
  templates and prove stable `0.5.5` wins over newer-timestamp `0.5.5-rc.1` and `0.5.05` caches.
- `prerelease-pre-fix-red.txt`: the same current tests run against source commit `20bde39`,
  before the resolver fixes. Both twins fail only the prerelease and leading-zero assertions at 11/2.
- `mutation/result.json`: controls pass; deleting the safe stop independently from each engine twin
  makes both focused tests fail because iteration two restores the shared HEAD and erases iteration
  one's accepted edit. The four raw run logs are beside the result.
- `package-validation.txt`: all three manifests agree on 0.5.3 and the shared dual-host package,
  hooks, skills, and six wrapper sources are internally consistent.
- `root-gate.txt`: the complete configured gate passed both twins after these changes.
- `review-fixes.txt`: both migration twins pass 44/0, the exact 0.5.3 manifest assertion is restored,
  package validation passes, and the final full gate is PowerShell 450/0 plus Bash 443/0.
- `consumer-rollout.txt`: sanitized raw command/output transcripts record source and installed-cache
  SHA-256 hashes, exact versions and paths, hook freshness, PR bases and HEADs, changed-file scope,
  zero config diffs, preserved routing, all six consumer wrapper hashes, real setup checks and dry-runs,
  their exit codes, and clean pre/post status for all five consumers.
- `review.txt`: the independent review history. Two FIX-THEN-SHIP rounds drove exact-version,
  evidence, documentation, prerelease, and leading-zero SemVer fixes; the final fresh-context
  re-review returned SHIP with no findings and left its detached worktree clean at `6cfe552`.
