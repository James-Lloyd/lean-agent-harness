# Local repair and cleanup — 2026-10-15

Requested by the operator after a read-only health audit. No engine, test, schema,
model routing, or product configuration was changed. Source base: `b4cfd89`.

## Repair and verification

- Relocation left Git worktree administrative links pointing at the old checkout.
  `git worktree repair` repaired the model-routing worktree, locked fleet worktree,
  and nested fleet child at their current locations.
- Native Codex 0.162.1 and Claude installers added the GitHub marketplace and installed
  enabled `lean-agent-harness@lean-agent-harness` version 0.5.4 at user scope.
  The normal wrappers now discover an installed engine without an environment override.
  `installed-plugins.json` captures both enabled installs and the absent compatibility file.
- The main checkout's `harness/codex-setup.ps1` regenerated its ignored Codex files
  using the installed plugin. Both twins report fresh.
- `verify-local.ps1` captures normal wrapper behavior after repair, with exit codes,
  measured durations, and paths scrubbed before writing evidence:
  - `powershell-freshness.txt:1`: exit 0, 1.45 seconds.
  - `bash-freshness.txt:1`: exit 0, 8.48 seconds.
  - `powershell-loop-dry-run.txt:1`: exit 0, 2.29 seconds, reaches “would pipe”.
  - `bash-loop-dry-run.txt:1`: exit 0, 4.00 seconds, reaches “would pipe”.
  - `package-validation.txt:1`: exit 0, 5.57 seconds, package 0.5.4 consistent.
- Earlier in this same session, the full source gate at `b4cfd89` passed PowerShell
  **451/0** and Bash **444/0**, with final `GATE: green (both twins)` and exit 0.
  Those are baseline results, not a second post-repair full run. Product source and
  tests are unchanged; focused installed-wrapper checks above verify the local repair.

## Cleanup performed

- Removed clean, merged `chore/phase-model-routing-2026-09-29` worktree using
  `git worktree remove`, without force. Tracked and untracked status was empty;
  ignored skills were all generator-owned. Its two gate logs were retained as
  `retained-model-routing-bash.log.txt` and `retained-model-routing-gate.log.txt`
  with local home/check-out paths scrubbed before writing.
- Deleted five local branches using `git branch -d`, after proving each was an
  ancestor of `origin/main` with `git merge-base --is-ancestor`:

  | Branch | Tip |
  | --- | --- |
  | chore/phase-model-routing-2026-09-29 | 8d80611 |
  | codex/hook-activation-ratchet | c7bce56 |
  | codex/overnight-guide-root-gate | 3fcd1fc |
  | worktree-codex-single-review | 5b69040 |
  | worktree-overnight-stage1b | 5fba521 |

- Removed 39 main-checkout run directories, `run-001` through `run-039`, only after
  checking each was empty or contained solely `.budget.json` with the sole field
  `tokensSpent: 0`. Removed individual budget files and then empty directories;
  no recursive filesystem delete was used. Kept highest `run-040` to preserve
  monotonic run-ID allocation. Older directories had no ledger or transcript.
- Removed empty root `.tmp/` and empty `.claude/worktrees/codex-native-plugin/`.
- Remote branches, unmerged branches, specifications, and existing tracked
  evidence were preserved. Main remains clean at `b4cfd89`.

## Preserved unfinished work

The fleet parent remains locked and its child remains registered. The child's
`docs/overnight.md` is still modified. Its SHA-256 before and after cleanup is
`2F5D00BC548201D74DD2E73EC3E6B783A29C2678765A31E5455997C9C22BC913`.
No fleet worktree was removed or unlocked.

## Hook activation limit

Native plugin installation is verified. The user-level compatibility hook file
is absent. The activation skill requires a fresh-session `/hooks` check first;
the operator replied “I can't check right now.” No global hook file was written
and no hook trust was fabricated. Hook execution is therefore **not verified**.
In a fresh Codex session, review/trust the four native harness entries. If zero
entries appear, use `harness-codex-activate` for the compatibility install, then
review/trust and perform its disposable denial live-fire. The maintenance task
stays open for that final manual check. Overnight/fleet live-fire tasks remain open.

## Review

Independent reviewer returned **SHIP — zero remaining blockers** after the fix
below. It independently rechecked both normal freshness twins, clean main,
ancestry of all five deleted tips, retained highest run-040, and the protected
fleet document hash. It confirmed the task correctly stays open for hook trust
and denial live-fire. Review scope was this maintenance record and live local
state, not a claim that runtime hooks or overnight operation were exercised.

The first review found that a later native Codex cache materialization changed the
same-version mtime tie-break from the Claude cache to the Codex cache, invalidating
the generated input digest's plugin-root path. Regeneration was repeated through
the normal wrapper after installation/inventory settled; a further `codex plugin
list --json` and the full focused smoke then passed. The timings above and logs are
from that final run. Its disposable dry-runs advanced the retained run ID to 040.
