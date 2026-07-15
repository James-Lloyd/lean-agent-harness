<!--
  Nested component CLAUDE.md template. Copy into a component directory (e.g. frontend/CLAUDE.md) for a
  non-trivial component in a multi-component repo. Keep it a LOCAL map — it inherits the root CLAUDE.md;
  only record what's specific to this component. Stay short. {{PLACEHOLDERS}} filled by /harness-init.
-->

# {{COMPONENT_NAME}}  ({{COMPONENT_PATH}})

{{COMPONENT_ONE_LINER}}  ·  part of the project mapped in [`../CLAUDE.md`](../CLAUDE.md).

## Stack & commands
- **Stack:** {{COMPONENT_STACK}}  (profile: `harness/profiles/{{COMPONENT_PROFILE}}.json`)
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
<!-- Add via /ratchet when a failure is specific to this component. Project-wide rules go in ../CLAUDE.md -->
{{COMPONENT_RATCHET_RULES}}
