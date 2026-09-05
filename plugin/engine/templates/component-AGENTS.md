<!--
  Nested component AGENTS.md template. Copy into a component directory (e.g. frontend/AGENTS.md) for a
  non-trivial component in a multi-component repo, alongside the one-line component-CLAUDE.md shim
  (Claude Code reads this map through that `@AGENTS.md` import). Keep it a LOCAL map — it inherits the root AGENTS.md;
  only record what's specific to this component. Stay short. {{PLACEHOLDERS}} filled by /harness-init.
-->

# {{COMPONENT_NAME}}  ({{COMPONENT_PATH}})

{{COMPONENT_ONE_LINER}}  ·  part of the project mapped in [`../AGENTS.md`](../AGENTS.md).

## Stack & commands
- **Stack:** {{COMPONENT_STACK}}  (profile: `{{COMPONENT_PROFILE}}`)
- **Run:** `{{COMPONENT_RUN}}`  ·  **Build:** `{{COMPONENT_BUILD}}`  ·  **Test:** `{{COMPONENT_TEST}}`
- All commands run **from this directory** (`{{COMPONENT_PATH}}`).

## Gate (run in this directory)
```
{{COMPONENT_FORMAT}}
{{COMPONENT_LINT}}
{{COMPONENT_TYPECHECK}}
{{COMPONENT_BUILD}}
{{COMPONENT_TEST}}
```
<!-- Keep this block in sync with this component's gate in harness/harness.config.json. Drop any step
     that is null there (e.g. remove the build line if the component has no build). -->


## Layout & entry points
- {{COMPONENT_ENTRY_POINTS}}

## How this component talks to the others
{{COMPONENT_INTERFACES}}  <!-- e.g. "calls backend at /api; contract in specs/020-api.md" -->

## Component rules (the ratchet — local failures only)
<!-- Add via /ratchet when a failure is specific to this component. Project-wide rules go in ../AGENTS.md -->
{{COMPONENT_RATCHET_RULES}}
