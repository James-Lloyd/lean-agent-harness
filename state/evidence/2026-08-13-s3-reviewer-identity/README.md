# S3 — separate-reviewer-identity confirmed against a real PR

Part of the risk-gated promotion S3 dogfood. This directory captures the one fact that
`docs/promotion.md` §3 asserts and that promotion's auto-approve step depends on:

> **GitHub rejects self-approval.** If the token that opens the PR is the token that calls
> `gh pr review --approve`, the approval fails — always. Auto-approval needs a second identity
> with write access.

## Setup
- **Repo:** `James-Lloyd/lean-agent-harness`
- **Author identity:** `James-Lloyd` (ADMIN) — the account that opens PRs and runs the harness.
- **Reviewer identity:** `jl-pr-reviewer` — separate account, confirmed **write** collaborator
  (`role_name: "write"`, `push: true`) via `repos/.../collaborators/jl-pr-reviewer/permission`.

## What the two logs show
- `self-approval-rejected.txt` — `James-Lloyd` (the author) attempts `gh pr review --approve` on
  their own PR → GitHub refuses. This is the failure the promotion flow treats as HUMAN.
- `second-identity-approved.txt` — `jl-pr-reviewer` runs the same command on the same PR →
  approval succeeds.

Together these confirm the precondition: a distinct write identity is both **necessary** (self
fails) and **sufficient** (second succeeds) for the auto-approve step. Promotion remains
`enabled: false`; this only establishes the identity half of S3.
