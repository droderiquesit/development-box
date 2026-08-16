---
agent: security-agent
profile: code-review
---
Perform a security review of this repository.

1. Run `devbox security scan` and triage every finding as CONFIRMED, MITIGATED or
   FALSE POSITIVE with a stated reason.
2. Review beyond the scanners:
   - secrets in code, git history, CI logs and container layers
   - IAM/RBAC breadth against what the workload actually needs
   - public exposure: 0.0.0.0/0, public buckets, unauthenticated endpoints
   - encryption at rest and in transit; logging and audit trails
   - injection: shell, SQL, template, and prompt injection into AI/MCP surfaces
   - supply chain: unpinned deps, unverified downloads, mutable image tags,
     unpinned GitHub Actions
   - container posture: user, capabilities, filesystem, mounts
3. Rank by exploitability in this codebase, not by CVSS.

Never print a secret value. If you find one, report the file and line, say what
kind of credential it appears to be, and state that it must be rotated
immediately — committing it is compromising it.
