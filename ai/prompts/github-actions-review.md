---
agent: github-agent
profile: balanced
---
Review the GitHub Actions workflows in `.github/workflows/`.

Security first — these are the ones that cause real incidents:

1. **Third-party actions pinned to a full commit SHA?** A tag is mutable.
2. **`pull_request_target` or `workflow_run` checking out untrusted code?** That
   combination runs attacker-controlled code with a privileged token.
3. **Untrusted input interpolated into `run:`?** `${{ github.event.* }}` inside a
   shell block is script injection. It must go through `env:`.
4. **`permissions:` least-privilege?** Default `contents: read`, widened per job.
5. **Secrets** — any risk of one reaching a log, a step summary, an artifact, or
   a fork?
6. **OIDC used instead of long-lived cloud credentials?**

Then correctness and hygiene:

7. Run `actionlint`, `yamllint` and `shellcheck` and report what they find.
8. Runner images pinned where reproducibility matters; timeouts on every job;
   `concurrency` groups; cache keys that change when inputs change.
9. Are the checks that gate merging actually the checks that matter?

Give file, line, severity, and the exact fix.
