# Sources

The practices in this harness are a synthesis of these works. Each principle in
[`harness-philosophy.md`](./harness-philosophy.md) traces back to one or more of them.

| # | Source | Key ideas taken |
|---|--------|-----------------|
| 1 | Anthropic — *Effective harnesses for long-running agents* | Initializer + coding agent split; durable state artifacts (`progress.txt`, JSON feature list, `init.sh`); JSON manifest as anti-"declare victory" guardrail; deterministic session-startup ritual; real user-level verification (Puppeteer) over curl/unit tests. |
| 2 | Anthropic — *Harness design for long-running apps* | Planner / Generator / Evaluator three-agent system; **sprint contracts**; tuned skeptical evaluator with hard per-criterion thresholds; compaction vs. full context reset; file-based agent handoffs; re-examine the harness on every new model. |
| 3 | Martin Fowler / Birgitta Böckeler — *Harness engineering* | **Guides (feedforward) + sensors (feedback)**, both required; computational vs. inferential sensors; keep quality left; Ashby's Law → narrow the production space; linters carrying repair instructions; structural/architecture tests; harnessability. |
| 4 | OpenAI — *Harness engineering (Codex)* | `Agent = Model + Harness` (horse-tack metaphor); map-not-manual context (~100-line AGENTS.md, 88 nested files); `docs/` skeleton; mechanical doc-health enforcement; "garbage collection" drift control; correction over prevention; executable acceptance criteria. *(Primary URL 403'd; via secondary summaries — verify before external quoting.)* |
| 5 | Geoffrey Huntley — *Ralph* | Stateless `while` loop + stateful files (`PROMPT.md`, `fix_plan.md`, `AGENT.md`, `specs/`); **one item per loop**; search-before-assuming; no placeholders; fan-out reads / serialize the test gate (500 vs 1); deterministic back-pressure; greenfield-only caution. |
| 6 | Ex-Meta L8 (Kun Chen) — *Agentic engineering* | Be an engineering manager, not a coder; ask for outcomes + the *why*; **review in a fresh context**; unit tests aren't enough — demand e2e evidence; auto-rollback + token budget (gnhf); plain-file memory for portability; teach the agent from failures. |
| 7 | Addy Osmani — *Agent harness engineering* | **The ratchet principle**; attention is scarce (minimal rules); tool economy; silent success / verbose failure; separation of generation and judgment; hook taxonomy (lifecycle scripts); progressive disclosure via skills; "a harness is a living system." |

## Where to dig deeper
Attributed in the sources above and worth reading: Viv Trivedy ("Anatomy of an Agent Harness"),
Dex Horthy / HumanLayer ("Skill Issue"), Simon Willison (agent-loop definition), Fareed Khan
(Claude Code architecture breakdown), and the `awesome-harness-engineering` list.
