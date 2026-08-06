# Evidence — setup asks for model + effort per phase (2026-08-06)

**Feature:** when the harness is added to a new *or existing* repo, setup interviews the human for the
model and reasoning effort of each phase, leading with our recommended defaults.

What actually changed, precisely — `/harness-init` already interviewed for *model*:

- **NEW `plugin/skills/model-routing/SKILL.md`** — single source of truth for the defaults table, the
  interview recipe, the constraints, and the write-all-surfaces contract. Both setup paths point here,
  so a retune can't leave a stale copy in a sibling command (ratchet [2026-07-26]).
- **`/harness-init`** — routing is now interview item **2.8** (was only a write-time step), covers
  **effort**, and its inline table is deleted in favour of the skill.
- **`/harness-migrate`** — **new step 5**: the existing-repo half, which previously never asked. Reports
  whether a `models` block is absent / legacy-partial / complete and offers the interview. Report-only
  by default, explicit go-ahead to write, its own commit.
- **`/harness-doctor`** — a missing `models` block stays ✅ but now says what it costs and names the
  command that fixes it; check 10(c) gains the consumer-repo case (see below).
- **Twin test** pinning the skill's table to the shipped config, in both suites.

## Artifacts

| File | What it shows |
|------|---------------|
| `run-tests-ps.txt` | PowerShell self-tests — **150 passed, 0 failed** (143 before + 7 new) |
| `run-tests-bash.txt` | bash self-tests — **141 passed, 0 failed** (134 before + 7 new) |
| `mutation-test.txt` | Each new guard proven to FAIL on real drift — including the two false-passes the reviewer found and the StrictMode abort |
| `skills-frontmatter.txt` | The new skill is discoverable: name/description parse, matches the other four skills' shape |
| `skill-vs-config.txt` | Skill defaults table == shipped `harness.config.json`, phase by phase |

## Review — fix-then-ship, 1 blocker (fixed before commit)

**The blocker was a real design bug, caught pre-ship.** The skill's write contract told the agent to
write "the agents' frontmatter". In the **plugin dev repo** that's correct. In a **consumer repo** —
exactly who runs `/harness-migrate` — it resolves to the shared plugin cache
(`~/.claude/plugins/…`): outside the project, so not revertible with `git`; shared with every other
repo on the machine; and wiped by the next `/plugin update`. Widening migrate's `allowed-tools` with
`Edit`/`Write` is what made it reachable.

Fixed by making the write contract location-aware — consumer repos write **exactly two files**
(`harness.config.json` + `.claude/settings.json`), which is complete, because `/work` pins each
subagent from `config.models` per spawn and the frontmatter is only a default. Migrate's carve-out now
states that two-file limit explicitly, and doctor check 10(c) grades frontmatter divergence as ℹ️ (not
❌) when the agents come from the plugin cache.

Also fixed from the same review: the test pinned values row-wide, so corrupting the `implement` effort
cell false-passed off the neighbouring fallback cell, and the fallback column wasn't asserted at all
(both now column-wise — see `mutation-test.txt` cases 2–3); a missing config phase threw under
StrictMode and aborted the PS suite mid-run (now fails cleanly and continues — case 4); the codex probe
ignored `auth: api-key`; `/harness-init` could run the interview twice; and "accept the recommended
routing" could silently overwrite a deliberately-tuned legacy block (the interview now shows
current-vs-proposed and offers *keep mine / fill gaps only*).

Two failure classes recorded as ratchets in `CLAUDE.md`.

## Note on the PS/sh twins

Writing the test, the PowerShell twin failed where bash passed: in a `-like` wildcard pattern the
backtick is the **escape** character, so `` *`opus`* `` consumed the backticks and matched nothing.
Fixed with `[char]96` + `.Contains()`, commented in place. Same class as the PS-5.1 rules in
`plugin/engine/CLAUDE.md`.
