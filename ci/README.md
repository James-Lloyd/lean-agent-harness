# ci/

Ready-to-activate CI for the harness.

[`github-harness-selftest.yml`](./github-harness-selftest.yml) runs the harness self-tests
(`harness/tests/`) on every push/PR — Linux (bash) and Windows (PowerShell). It lives here rather than
in `.github/workflows/` so the repo can be pushed with a token that lacks GitHub's `workflow` scope.

**To enable it:**
```bash
mkdir -p .github/workflows
cp ci/github-harness-selftest.yml .github/workflows/harness-selftest.yml
git add .github/workflows/harness-selftest.yml && git commit -m "ci: enable harness self-tests"
git push
```
If the push is rejected for the `workflow` scope, either run `gh auth refresh -h github.com -s workflow`
first, or add the file through the GitHub web UI (which isn't subject to that restriction).
