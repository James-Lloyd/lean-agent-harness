# Sandboxing for unattended runs

`autonomy.mode: auto` runs the loop **unattended** — a fresh headless `claude` per iteration, no human at
the keyboard to answer a permission prompt or veto a checkpoint. This doc explains why that wants a
sandbox, how the harness recognizes one, and the two supported profiles for running `auto` safely.

## Why a sandbox

The harness has defense-in-depth, but **defense-in-depth is not a sandbox**:

- The **destructive-command deny-list** (the `block-destructive` PreToolUse hook) matches both shell
  tools and fails closed on a denylist hit. It is a denylist — it stops the *obvious* footguns
  (`rm -rf`, `git push --force`, `DROP TABLE`, secret exfil), not everything an agent could do.
- `--dangerously-skip-permissions` (set when `autonomy.skipPermissions: true`) **voids the permission
  layer entirely** — deny/ask rules lose their teeth. Only run that inside real isolation.
- On **Windows there is no native OS sandbox** for this. The supported answer is WSL2 or a devcontainer
  (both are Linux) — see the two profiles below.

So for unattended `auto` you want an environment where the *worst case* is bounded: no host filesystem to
scribble on, secrets scoped to the run, an ephemeral workspace you can throw away.

## How detection works

The loop checks whether it is sandboxed at startup. If `mode: auto` and it is **not**, it prints a loud
warning (it does **not** block — in `auto` there is no human to confirm, so a warning is the honest
thing). The predicate is `is_sandboxed` (bash, `plugin/engine/lib/gate.sh`) / `Test-Sandboxed`
(PowerShell, `plugin/engine/lib/gate.ps1`), which are capability-equivalent mirrors.

**`HARNESS_SANDBOX` is the explicit, cross-platform contract and always wins when set:**

| `HARNESS_SANDBOX` | Result |
|-------------------|--------|
| `1`, `true`, `yes` (any case) | **sandboxed** |
| `0`, `false`, `no`, empty | **not sandboxed** (overrides any auto-detected marker) |
| unset | fall through to auto-detection |

When `HARNESS_SANDBOX` is **unset**, the predicate auto-detects common container markers — **any** present
means sandboxed:

- file `/.dockerenv` exists (Docker)
- file `/run/.containerenv` exists (Podman)
- `CODESPACES` is set (GitHub Codespaces)
- `REMOTE_CONTAINERS` is set (VS Code Dev Containers)
- `DEVCONTAINER` is set (devcontainer spec)
- `container` is set (systemd-nspawn / Podman — value is the runtime name, e.g. `lxc`)
- `/proc/1/cgroup` exists and contains `docker`, `containerd`, `lxc`, or `kubepods` (incl. Kubernetes)

> **Bare WSL2 is NOT auto-detected.** WSL2 shares your Windows kernel and can reach `/mnt/c`, and it trips
> none of the markers above. If you run `auto` in WSL2 you must **opt in** explicitly with
> `export HARNESS_SANDBOX=1` (after cloning into the WSL-native FS — see Profile B). This is deliberate:
> WSL2 is weaker isolation than a container, so you affirm it rather than get it for free.

## Profile A — devcontainer (recommended, strong isolation)

Copy `plugin/engine/templates/devcontainer.json` to your project's `.devcontainer/devcontainer.json`,
then open the repo in the container (VS Code "Reopen in Container", or the `devcontainer` CLI). The
template is strict JSON (no `//` comments — a harness self-test parses it) and is the **no-host-FS**
variant. Security properties it gives you:

- **`containerEnv.HARNESS_SANDBOX = "1"`** — the loop recognizes the container as a sandbox, so no warning.
- **Volume workspace, no host bind** — `workspaceMount` uses a named Docker **volume**
  (`source=harness-workspace,type=volume`) mounted at `/workspace`, so the agent never touches your host
  filesystem. The workspace is ephemeral: delete the volume to reset.
- **`specs/` read-only** — the **authoritative** guard is the loop's `HARNESS_LOCK_SPECS` protect-specs
  PreToolUse hook: it blocks any agent edit under `specs/` regardless of filesystem permissions, so the
  contract can't be rewritten to make work "pass". The template's `postCreateCommand` also runs
  `chmod -R a-w specs` as **best-effort** FS hardening — note it is not a hard guarantee (the same
  container user, or root in the image, can chmod it back, and it no-ops if `specs/` is absent); the hook,
  not the chmod, is what actually enforces the read-only contract.
- **Secrets via env, never baked** — `remoteEnv` pulls `ANTHROPIC_API_KEY` / `CODEX_API_KEY` from your
  **host** env with `${localEnv:...}`. They are never written into the image or committed.
- A minimal Ubuntu base plus the `github-cli` and `node` features (node is needed by the plugin's hook
  dispatcher; `gh` for PR flows). Trim what you don't use.

> **Network egress** is a property you configure at the **container/host** level (e.g. a locked-down
> Docker network, an egress proxy, or `--network none` where the run doesn't need the internet). It is
> **not** engine-enforced — the harness cannot police outbound traffic for you.

## Profile B — raw WSL2 (weaker, opt-in)

For Windows users without Docker, WSL2 is a workable fallback with **weaker** isolation (shared kernel;
WSL can reach `/mnt/c`):

1. Clone the repo into the **WSL-native filesystem** (e.g. `~/work/...`), **not** `/mnt/c/...` — running
   from `/mnt/c` both defeats the isolation and is slow.
2. Install the toolchain: `jq`, `node`, `git`, plus your project's gate tools and the `claude` CLI.
3. Opt in to the sandbox contract: `export HARNESS_SANDBOX=1` (put it in your shell profile for the run).
4. Run the loop: `bash harness/loop.sh --mode auto`.

Because the kernel is shared and `/mnt/c` is reachable, keep secrets out of any env you don't want the
agent to see, and don't point it at host paths you care about. A devcontainer (Profile A) is stronger;
prefer it when you can run Docker.

## The warning you'll see outside a profile

Run `auto` on your bare host (no `HARNESS_SANDBOX`, no container markers) and the loop prints, before the
first iteration:

```
⚠️  AUTO mode but NOT in a recognized SANDBOX. This run is full-auto and UNATTENDED.
    Unattended auto should run inside the documented isolation profile (container/devcontainer or
    WSL2-native FS), not directly on your host. The destructive-command deny-list is defense-in-
    depth, NOT a sandbox — and --dangerously-skip-permissions voids it entirely.
    See docs/sandboxing.md. Mark a sandbox explicitly with:  export HARNESS_SANDBOX=1
```

It warns but does not stop (in `auto` there is no human to confirm). Supervised mode and any run inside a
recognized sandbox print nothing.
