# Fresh-context review of this batch — `VERDICT: SHIP`

The `reviewer` subagent, fresh context, reasoning from the diff and the project principles rather than
from the session that produced it. Pinned to Fable 5.1 by frontmatter; that spawn died on the model's
usage cap, so it was re-spawned with `model: opus` per the 2026-07-14 project rule. 54 tool uses,
25 minutes.

It re-ran the bash suite four times (307/0) and independently re-ran `mutation-proof.sh`, reproducing
the fail-open and the fix — the pre-fix body returns `LOW`/`AUTO` on the 200 KiB fixture where the
shipped one returns `HIGH`/`HUMAN`. It scanned the whole diff for tokens, keys and absolute local
paths and found none.

**No blockers. Four should-fix, five nits. Every should-fix is applied; three nits applied, two
recorded rather than acted on.**

## What it found, and what was done

| # | Finding | Disposition |
|---|---|---|
| 1 | The one fixed site that failed **OPEN** — fleet's protected-path tamper guard — was the only one of three with no oversized regression test, contradicting the ratchet this same batch added. | **Fixed.** The `T-EVIL` worker now stages ~2000 filler files with a protected path sorting first, so the guard sees a ~100 KiB list. Both twins: fleet-queue 31/0 → 34/0. |
| 2 | The two PR-binding prose pins were file-wide substring greps. `headRefOid` and `baseRefName` each occur about five times in `promote.md`, so deleting §1's binding block outright still passed them off the §7 template. The project's own `[2026-08-06]` ratchet class. | **Fixed.** Both twins now pin the distinctive §1 requirement text, which occurs exactly once each. |
| 3 | §8's AUTO path posted the structured approval comment *before* re-checking the binding, so a PR that moved during §4 would get an AUTO-shaped comment immediately followed by an ESCALATED one. | **Fixed.** The re-check is now step 1 and gates the comment. |
| 4 | The Runs table called each probe record "a §7 `risk.json`", but the records omit the `pr` object §7 now requires, and no `risk-outcome` row exists — §8a is entirely unexercised. | **Fixed by rewording**, not by fabricating a `pr` block: the probes classify *ranges*, most of which never had a PR. §8a is named in the still-human-gated list. |
| 5 | `PR_HEAD` was carried forward and never consumed — §8's re-check compared against local `HEAD`. | **Fixed.** §8.1 now compares against `$PR_HEAD`, the head actually classified, which is the stricter check. |
| 6 | "Run the §9 probes first" was a forward reference to the last section. | **Fixed.** The probes are now §0, at the top of the procedure. |
| 7 | The App-claim pin matches an exact sentence, so a reworded reintroduction would escape it. | **Accepted.** Verified load-bearing for this regression; a looser pin would collide with the replacement prose, which legitimately uses the words "installation token". |
| 8 | `[bool]$ReviewerConfigured` coerces any non-empty string to `$true`, while the bash twin requires a literal `1` — a twin divergence on the last gate before AUTO. Pre-existing, shared with the three precondition bools, unreachable from the documented caller. | **Recorded, not fixed.** Now its own `fix_plan` item. It has been raised twice (the 2026-09-05 primary's nit 2 and here), so it is written down rather than carried in review comments a third time. |
| 9 | `plugin.json` jumps 0.3.5 → 0.3.7, skipping 0.3.6. | **Accepted.** Monotonic and harmless; 0.3.6 existed only in an intermediate rebase resolution. |

## Its proposed ratchet, adopted

> A fix applied to N call sites gets its regression test at every site that failed OPEN, not only at
> the site where it was discovered.

Added to `plugin/engine/AGENTS.md`, with the corollary this batch learned twice: the test must
actually reproduce the failure. For the SIGPIPE defect the match has to sort **early** in the
oversized input, or grep drains the pipe, printf exits cleanly, and the broken code passes.

## One non-finding worth keeping

The reviewer's first suite run died with a bash syntax error at a partial line. That was this session
writing `run-tests.sh` while the reviewer's bash was streaming it from its script fd — not a defect.
It did not recur across four subsequent runs. Worth knowing: a long-running review and an active
editor on the same tree can manufacture a phantom failure.
