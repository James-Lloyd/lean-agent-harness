# Fix plan

The prioritized task stack. **Highest priority at the top.** The loop takes the single top unchecked
item each iteration. Keep items small enough to finish in one iteration; split anything bigger.

Format: `- [ ] <imperative task>  — done when: <verifiable condition>`

> Empty by design. Run `/plan "<what you want>"` to populate it, or add items by hand. The loop stops
> when there are no unchecked items left (config `loop.stopWhenPlanEmpty`).

## Tasks
<!-- example:
- [ ] Scaffold the project skeleton  — done when: app builds and the gate runs green on an empty app
- [ ] Add health-check endpoint  — done when: GET /health returns 200 + {status:"ok"}, with a test + e2e curl evidence
-->

## Done
<!-- move completed items here (or just tick them) so the live stack stays readable -->
