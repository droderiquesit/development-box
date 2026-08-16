# Security Guardrails - development-box

**Repository Owner:** David Roderiques (<droderiques.it@gmail.com>)  
**Visibility:** Private  
**Created:** 2026-08-15  
**Last Updated:** 2026-08-15

---

## 1. Repository Access Control

### Authentication

- ✅ Repository is **PRIVATE** — only accessible to authorized users
- ✅ Requires GitHub authentication for all operations
- ✅ SSH key or personal access token required for local operations

### Access Policy

- **Owner:** <droderiques.it@gmail.com> (full permissions)
- **Collaborators:** None (as of setup)
- **Public Access:** Disabled

---

## 2. Branch Protection Rules

### Main Branch (`main`)

- ✅ Require pull request reviews before merge (1+ reviewer)
- ✅ Dismiss stale pull request approvals when new commits are pushed
- ✅ Require status checks to pass before merge
- ✅ Require branches to be up to date before merge
- ✅ Restrict who can push to matching branches (owner only)
- ✅ Enforce rules on administrators

### Development Branch (`develop`)

- ✅ Require pull request reviews before merge (1+ reviewer)
- ✅ Require status checks to pass
- ✅ Restrict direct pushes (use PRs only)

---

## 3. Credential & Secret Management

### What Should NEVER Be Committed

- ❌ API keys, tokens, or credentials
- ❌ Database passwords
- ❌ Private keys (SSH, PGP, etc.)
- ❌ Cloud provider credentials (AWS, Azure, GCP)
- ❌ OAuth tokens or refresh tokens
- ❌ SSH keys
- ❌ Configuration files with sensitive data

### Credential Safe Storage

- ✅ Use `.env` files (never commit — add to `.gitignore`)
- ✅ Use GitHub Secrets for CI/CD workflows
- ✅ Use environment-specific configuration
- ✅ Use credential management tools (1Password, LastPass, etc.)

### If Credentials Are Accidentally Committed

1. **Immediately revoke** the compromised credential
2. **Rotate** the credential to a new one
3. **Remove from history** using BFG Repo-Cleaner or git-filter-branch
4. **Force push** after cleanup (if you own the repo)

---

## 4. Code Security Best Practices

### Pre-Commit Checks

- ✅ Run security scanners before committing
- ✅ Check for secrets using `git-secrets` or similar tools
- ✅ Validate code formatting and linting
- ✅ Run unit tests

### Commit Standards

- ✅ Meaningful, descriptive commit messages
- ✅ Atomic commits (one logical change per commit)
- ✅ Reference issues/tickets when applicable
- ✅ Sign commits with GPG key (recommended for sensitive projects)

### Pull Request Standards

- ✅ Always create PRs — never push directly to main
- ✅ Write descriptive PR descriptions
- ✅ Link to related issues
- ✅ Request appropriate reviewers
- ✅ Ensure all CI checks pass before merge
- ✅ Delete branch after merge (auto-enabled)

---

## 5. File Structure & Permissions

```text
development-box/
├── .github/              # GitHub configuration
│   ├── workflows/        # CI/CD workflows
│   └── CODEOWNERS        # Automatic code review assignment
├── .gitignore            # Ignore sensitive/temporary files
├── SECURITY.md           # This file
├── README.md             # Project overview
├── LICENSE               # MIT or appropriate license
└── src/                  # Source code
    └── .gitkeep
```

### .gitignore Essentials

```gitignore
# Environment variables
.env
.env.local
.env.*.local

# Secrets and credentials
secrets/
*.key
*.pem
*.private

# IDE and OS files
.vscode/
.idea/
*.swp
*.swo
.DS_Store
Thumbs.db

# Dependencies
node_modules/
venv/
__pycache__/

# Temporary files
*.tmp
*.log
```

---

## 6. GitHub Security Features

### Enabled

- ✅ Private repository visibility
- ✅ Branch protection on `main` and `develop`
- ✅ Require status checks before merge
- ✅ Delete head branches on PR merge
- ✅ Auto-merge PRs (when all checks pass)

### Recommended Additions

- 🔧 GitHub Code Scanning (Dependabot alerts)
- 🔧 Secret scanning alerts
- 🔧 CODEOWNERS file for automatic reviewers
- 🔧 Issue and PR templates

---

## 7. Credential Rotation Schedule

| Credential Type | Rotation Frequency | Next Rotation |
|---|---|---|
| GitHub Personal Access Token | Every 90 days | November 14, 2026 |
| SSH Keys | Every 180 days | February 14, 2027 |
| Database Credentials | Every 60 days | October 15, 2026 |
| API Keys | Every 90 days | November 14, 2026 |

---

## 8. Incident Response

### If Repository is Compromised

1. **Immediately revoke** all access tokens and credentials
2. **Change** all passwords related to the account
3. **Check** recent commits and PRs for unauthorized changes
4. **Review** access logs and collaborators
5. **Contact GitHub Support** if needed
6. **Rotate** all sensitive credentials

### If Secrets Are Leaked

1. **Revoke** the leaked credential immediately
2. **Search** git history for the secret using BFG or git-filter-branch
3. **Force push** the cleaned history
4. **Generate** a new credential
5. **Update** all systems using the old credential

---

## 9. Monitoring & Logging

- ✅ Monitor GitHub notifications for suspicious activity
- ✅ Review commit history regularly
- ✅ Check collaborators and SSH keys periodically
- ✅ Enable GitHub security alerts
- ✅ Monitor for failed login attempts

---

## 10. Communication & Incidents

**Security Contact:** David Roderiques (<droderiques.it@gmail.com>)

For security issues:

- **Do not** create public GitHub issues for security vulnerabilities
- **Email** security concerns directly to the owner
- **Provide** detailed description of the vulnerability
- **Allow** time for patch development before disclosure

---

## Revision History

| Date | Changes | Author |
|---|---|---|
| 2026-08-15 | Initial security policy creation | David Roderiques |

---

**Last Reviewed:** 2026-08-15  
**Next Review:** 2026-09-15 (monthly)
