# GitHub Actions example

A workflow that passes `devbox github check` and demonstrates the security
patterns the `github-agent` enforces.

```bash
cd examples
devbox github check
```

## The patterns that matter

These are the mistakes that cause real incidents, in the order they cause them:

1. **Pin third-party actions to a full commit SHA.** Tags are mutable; a
   compromised tag is a compromised build.
2. **Never interpolate untrusted input into `run:`.** `${{ github.event.* }}`
   inside a shell block is script injection. Pass it through `env:` instead.
3. **`pull_request_target` runs with a privileged token against untrusted code.**
   Never check out and execute PR code under that trigger.
4. **Least-privilege `permissions:`.** Default `contents: read`, widened per job.
5. **OIDC over long-lived cloud credentials.**
6. **Timeouts on every job**, and a `concurrency` group so pushes cancel
   superseded runs.
