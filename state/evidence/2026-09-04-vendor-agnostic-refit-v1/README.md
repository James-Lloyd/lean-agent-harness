# Evidence — vendor-agnostic refit V1: AGENTS.md is the map, CLAUDE.md imports it (2026-09-04)

Branch `worktree-feat+vendor-agnostic-refit`, plugin 0.3.1, design-doc `docs/design-docs/002-vendor-agnostic-routing.md` D1.

## User-visible behaviour: Claude Code loads the map through the `@AGENTS.md` import

Real headless session from this worktree (cwd = the worktree root, so its `CLAUDE.md` shim is the
project memory), asked for content that exists ONLY in `AGENTS.md`:

```
$ claude -p --model haiku --max-turns 1 "Without using any tools: quote, verbatim, the single line
  under the heading 'Task-claim convention' in your loaded project instructions that shows the stamp
  format (it contains 'wip:'). Then state which file that heading lives in according to those
  instructions. Two lines, nothing else."

and as your first commit stamp the task line with your branch — `- [ ] (wip: <branch>) <task>`.

AGENTS.md
```

The quoted line is byte-identical to `AGENTS.md` "Session isolation → Task-claim convention"; the
shim `CLAUDE.md` contains no such text. `--max-turns 1` and "without using any tools" rule out the
model reading the file itself — the content arrived through memory import.

Documented basis (verified by the fresh-context reviewer against code.claude.com/docs/en/memory,
section "AGENTS.md"): *"Claude Code reads CLAUDE.md, not AGENTS.md. If your repository already uses
AGENTS.md for other coding agents, create a CLAUDE.md that imports it … `@AGENTS.md` … On Windows,
creating a symlink requires Administrator privileges or Developer Mode, so use the @AGENTS.md import
instead."* Relative imports resolve relative to the importing file, so the nested shims
(`plugin/engine/CLAUDE.md`, the example components, the component template) resolve to their sibling map.

## Codex-side constraint check

Codex reads the `AGENTS.md` chain root → cwd with a 32 KiB cap. Sizes on this tree: root 8,124 B;
`plugin/engine/AGENTS.md` 6,371 B; component template 1,556 B; example root/frontend/backend
2,355 / 1,084 / 1,019 B. No BOM, no CRLF on any shim.

## Gate on the final tree

| Suite | Result |
|---|---|
| bash `harness/tests/run-tests.sh` | 245 passed, 0 failed (237 + 8 shim-shape assertions) |
| PS 5.1 `harness/tests/run-tests.ps1` | 255 passed, 0 failed (247 + 8) |
| bash `fleet-queue-test.sh` | 31 passed, 0 failed |
| PS 5.1 `fleet-queue-test.ps1` | 31 passed, 0 failed |
| migrate self-test (inside both suites) | green, now also asserts `AGENTS.md untouched` |
| pwsh | not installed on this box — CI job `harness-selftest` covers it |

Shim-shape assertions (per twin): root, `plugin/engine`, three example dirs each have `AGENTS.md` and a
`CLAUDE.md` whose first non-blank line is exactly `@AGENTS.md`; the template ships as a pair;
`{{PLACEHOLDERS}}` live only in `AGENTS.md`; the root shim is ≤ 25 lines.

## Sweep

83 exact-match prose edits (each asserted to match exactly once) plus 6 `git mv` renames. Remaining
`CLAUDE.md` mentions outside history were each judged by the fresh-context reviewer as Claude-specific
(the import itself, `--bare` discovery, the shim files, Anthropic doc quotes); the one miss it found
(`plugin.json` description) is fixed in the same commit.

## Fresh-context review

Reviewer agent on `claude-fable-5-1`: first pass REJECT (this evidence dir was missing — a real
"ticked without evidence" failure, now a ratchet line in `AGENTS.md`); findings 2–4 (plugin.json
description, doctor shim definition looser than the tests', template comment) applied. Second pass
verdict in the commit message.
