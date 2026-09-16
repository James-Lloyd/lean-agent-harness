# OVERNIGHT-CANARY-001 evidence

## Operator-visible correction

The overnight operator's allowlist guidance now states the repository's actual configuration:

- the `root` component runs `node harness/tests/gate.mjs`;
- that script dispatches the native self-test twin and, on Windows with Git Bash, the Bash twin; and
- the separate cross-cutting `gate` block has no configured commands because the component gate owns
  the repository's self-tests.

This replaces the stale claim that the repository's own root component is an empty-gate example. The
empty-gate warning now applies only when a consumer project's component gates and separate
cross-cutting gate all contain no commands.

## Acceptance map

- **Guide describes the wired cross-platform gate:** `docs/overnight.md` names the exact configured
  command and explains its twin dispatch.
- **Existing wiring remains valid:** focused verification reads the live config, checks the dispatcher
  target and syntax, and confirms both runner twins retain their gate-wiring assertions.
  `focused-check.txt:1-17` preserves the exact command, all 13 passing checks, and exit code 0;
  `run-focused-check.mjs` reproduces it. Pass `--output-dir <path>` to reproduce into a temporary
  directory without replacing the committed result; that override also passed 13/0 with exit code 0.
- **The configured root gate remains green:** `root-gate.txt:1` preserves the exact command,
  PowerShell passes 442/0 at `:540`, Bash passes 435/0 at `:1043`, the combined gate is green at
  `:1045`, and the captured process exits zero at `:1047`. `capture-root-gate.ps1` and
  `gate-capture.cjs` reproduce the capture. Pass `-OutputDir <path>` to keep the committed artifact
  unchanged; its temporary-directory self-test passed 12/0 with exit code 0.
- **Captured paths are scrubbed and mutation checked:** `scrubber-check.txt:1-16` preserves eight
  green controls covering native, forward-slash, doubled-separator, mixed-separator, and MSYS forms,
  plus four controls that catch the deliberately weakened legacy exact-match scrubber. The production
  helper normalizes those forms case-insensitively, checks the username directly, and runs a
  binary-inclusive `git grep -a` sweep. An earlier sandboxed gate attempt was discarded because the
  sandbox denied access to the user's Git ignore file and packaged `jq`; the recorded host run uses
  the gate's normal environment.
- **User-visible evidence exists:** this note records the corrected guidance and the distinction an
  overnight operator now sees.

Independent review round 1 returned FIX-THEN-SHIP because the warning omitted the cross-cutting-gate
case and the evidence only summarized results. `review-round-1.md` records both findings; this surface
addresses them with the corrected condition and reproducible artifacts above.

Independent review round 2 found weak future path scrubbing, missing output-directory overrides, and
a malformed sentence. `review-round-2.md` records those findings; the mutation-tested scrubber,
temporary output controls, and repaired sentence address them.

Independent review round 3 confirmed those functional fixes but found that the scrubber proof had
only positive controls. `review-round-3.md` records the finding; the legacy-scrubber mutant controls
now prove the corrected predicate catches the prior failure modes.

Independent review round 4 returned SHIP with no blocker, important, or minor findings. See
`review-round-4.md`.

No immutable specification changed.
