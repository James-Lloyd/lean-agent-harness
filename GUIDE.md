# The plain-English guide

This explains the harness with no jargon. If you've never touched one before, start here. (For the
deeper "why", see [`docs/principles/harness-philosophy.md`](docs/principles/harness-philosophy.md).)

---

## What is this, really?

When you use an AI coding assistant, the AI is only half of what matters. The other half is everything
*around* the AI — the instructions it reads, the rules it follows, the tests that catch its mistakes,
and the memory it keeps between sessions.

That "everything around the AI" is called a **harness**. This repo is a ready-made one you drop into
any project.

> **Analogy:** a brilliant new contractor shows up to build your house. Incredibly skilled, but they
> have amnesia — they forget everything overnight, and they'll happily declare a wall "finished" when
> it's only half up. The harness is the **clipboard, the blueprints, the building inspector, and the
> end-of-day notes** you give them. Same contractor, dramatically better house.

The AI is the contractor. **You** supply the harness. A good harness makes an average AI reliable; a
bad one wastes a great AI.

---

## Why bother?

Without a harness, an AI assistant:
- forgets what it did last time (every session starts from zero),
- says "done!" when things are actually broken,
- happily deletes a test to make an error go away,
- and wanders off-task on big jobs.

This harness fixes each of those with a simple, concrete mechanism. You don't have to trust the AI —
you trust the **checks**.

---

## The five ideas behind it (in one breath each)

1. **A map, not a manual.** The AI reads one short page (`CLAUDE.md`) that points to where things are —
   not a giant rulebook it'll ignore.
2. **Memory lives in files, not the AI's head.** Plans, progress, and decisions are written to disk, so
   a fresh AI session picks up exactly where the last one left off.
3. **One task at a time.** It does a single thing, finishes it properly, then moves on. No sprawling
   half-done messes.
4. **It has to prove it works.** "The tests pass" isn't enough — it must actually run the thing and show
   you (a screenshot, a real request, a log). Unit-green is not "done".
5. **The builder doesn't grade its own homework.** A *separate* check reviews the work with fresh eyes,
   because anyone marking their own work is too kind to it.

Everything else is just plumbing to make those five things automatic.

---

## What's a "gate"? (the most important word)

The **gate** is the set of checks the work must pass before it counts as done — usually: auto-format
the code, lint it, type-check it, run the tests, and (for the whole system) a real end-to-end test.

You tell the harness *what* your gate is **once** (during setup), in plain commands like `pnpm test` or
`pytest`. After that, the harness runs the gate automatically and refuses to call anything finished
until it's green. **The gate is the harness.** Get it right and everything else follows.

---

## What about projects with a separate frontend and backend?

Handled. Many projects are one folder containing two mini-projects — say a `frontend/` (in one language)
and a `backend/` (in another). The harness treats each as a **component** with its own gate, and it's
smart about it: edit a backend file and it runs the *backend's* checks; edit a frontend file and it runs
the *frontend's*. A final "do they work together?" test runs over both.

See [`examples/headless-fe-be/`](examples/headless-fe-be/) for a complete worked example.

---

## Brand-new project, or an existing one?

Both work, and the harness treats them differently because they *are* different:

- **Brand-new ("greenfield")** — there's no code yet. Setup writes down what you're going to build, picks
  the tools, and you're off. It can safely run more on its own.
- **Existing codebase ("brownfield")** — there's already working code with real users. Here the golden
  rule is **don't break what works**. So before changing anything, the harness runs **`/onboard`**: it
  reads your codebase, learns how it's built and tested, runs your existing tests to make sure they're
  all passing *first* (so it can tell later if *it* broke something versus something that was already
  broken), and learns your existing style so it fits in rather than imposing its own. It then works
  cautiously — small changes, on a side branch, double-checking it didn't break anything — and it won't
  go full-autonomous without you explicitly saying so.

You don't have to pick — `/harness-init` figures out which kind you have and does the right thing.

## Setting it up (about 5 minutes)

You need [Claude Code](https://claude.com/claude-code) installed, and `git`.

**1. Get the harness into your project.**
```bash
git clone https://github.com/James-Lloyd/lean-agent-harness.git my-project
cd my-project
rm -rf .git && git init        # make it your own fresh project
```

**2. Open the folder in Claude Code and run one command:**
```
/harness-init
```
That's the whole setup. It will ask you a handful of questions — what the project is, what language(s)
it uses, how to run the tests, and so on — and then fill in all the configuration for you. If it can
detect something itself (like your language), it won't even ask. If your project has a separate
frontend and backend, it'll spot that and set up both.

**3. You're ready.** There's nothing else to wire up.

---

## Using it day to day

Five commands cover almost everything (type them in Claude Code):

| You type | What happens |
|----------|--------------|
| `/plan "add user login"` | Turns your idea into a clear, checkable to-do list. |
| `/work` | Does the **next** task start-to-finish: plans it, builds it, tests it, reviews it, commits it — pausing to check with you along the way. |
| `/verify` | Runs the full gate and proves the latest change actually works. |
| `/review` | A fresh pair of (AI) eyes reviews the work skeptically. |
| `/ratchet "what went wrong"` | Teaches the harness a lesson so a mistake never repeats. |

The one to remember is **`/work`** — it walks a single task through the whole cycle
(**plan → build → check → review → save**) and checks in with you at each step. Run it, approve each
stage, repeat. That's the core loop of using this thing.

`/ratchet` is the secret sauce: every time the AI messes something up, you tell it once, and it writes
itself a permanent rule. The harness literally gets better the more you use it.

---

## How much should I let it run on its own?

There's a dial, in `harness/harness.config.json`, called `mode`:

- **`supervised`** (the default) — it stops and asks for your OK at each important step. Safe. Start here.
- **`auto`** — it runs on its own, doing task after task without stopping, until the to-do list is empty
  or it hits the limits you set. Powerful for grinding through a backlog overnight, but only turn it on
  once you trust your gate, because the gate is the only thing keeping it honest.

Either way there are safety rails baked in: a cap on how many steps it'll take, an optional spending
limit, automatic **undo** if a step breaks the build, and a blocker that refuses dangerous commands
(like deleting everything or force-pushing). For unattended runs:
```
# Windows
powershell harness/loop.ps1
# Mac / Linux
bash harness/loop.sh
```

---

## When something goes wrong

- **It says it's done but it's broken.** Run `/verify`. If the gate is wrong (e.g. the test command is
  incorrect), fix it in `harness/harness.config.json`. The gate is your safety net — keep it sharp.
- **It keeps making the same mistake.** Run `/ratchet "describe the mistake"`. It'll add a rule (or a
  check) so it can't happen again.
- **It's gone off the rails on a big task.** That's the harness telling you the task was too big — break
  it into smaller `/plan` items. One small thing at a time is the whole philosophy.
- **A long session is getting confused.** Run `/handoff`, then start a fresh session. It writes a tidy
  note so the new session continues seamlessly. The memory is in files, remember — nothing is lost.

---

## A tiny glossary

- **Harness** — everything around the AI that makes it reliable (this repo).
- **Gate** — the checks work must pass to count as done (format, lint, types, tests, end-to-end).
- **Component** — one buildable part of your project (e.g. `frontend/` or `backend/`); a simple project
  has just one.
- **The ratchet** — the habit of only adding a rule after a real mistake, so the rulebook stays short
  and every rule earns its place.
- **Loop** — doing one task, checking it, saving it, then repeating.
- **Supervised / auto** — whether it asks permission at each step, or runs on its own within limits.

That's it. Run `/harness-init`, then `/work`, and let the checks — not blind trust — keep things honest.
