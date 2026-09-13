---
name: harness-codex-activate
description: Activate and verify Lean Agent Harness hooks in Codex. Use after installing or updating the plugin, when /hooks shows zero harness entries, or when the user asks to enable Codex guardrails.
---

# Activate Codex guardrails

The plugin already packages its Codex hooks at `../../hooks/hooks.json`. First ask the user to open
`/hooks` in a new Codex session. If the four harness entries are installed, have the user review and
trust them; do not write global configuration.

On a Codex build where `/hooks` reports zero plugin entries, explain that this is the measured plugin-
hook loader limitation and offer the user-level compatibility install. Only after the user approves
the machine-wide write, run:

```text
node <installed-plugin-root>/scripts/install-codex-hooks.mjs
```

Resolve `<installed-plugin-root>` from this skill's own location; never guess a cache path. The
installer refuses to overwrite a non-harness `~/.codex/hooks.json`. If one exists, stop and give the
user a manual merge plan. Start a new session, open `/hooks`, review/trust the four entries, then run
the disposable destructive-command live-fire described in `docs/codex-setup.md` before relying on
the guard.

After a plugin update, repeat activation because user-level hook commands contain the installed
version's absolute plugin path. `node <installed-plugin-root>/scripts/install-codex-hooks.mjs --check`
reports whether the compatibility install is current.
