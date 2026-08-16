# development-box

**Secure Development Environment Repository**

- **Owner:** David Roderiques (droderiques.it@gmail.com)
- **Visibility:** Private
- **Repository URL:** https://github.com/droderiquesit/development-box
- **Created:** August 15, 2026

---

## Overview

`development-box` is a private development environment repository with comprehensive security guardrails, best practices, and operational guidelines. This repository serves as a secure workspace for development, experimentation, and collaboration.

### Key Features

✅ **Private Repository** — Only authorized access  
✅ **Branch Protection** — Enforced code review on main branches  
✅ **Security Policies** — Comprehensive security guidelines  
✅ **CI/CD Ready** — GitHub Actions workflows support  
✅ **Code Standards** — CODEOWNERS for review automation  

---

## Quick Start

### Clone the Repository

```bash
git clone git@github.com:droderiquesit/development-box.git
cd development-box
```

### Setup Local Environment

```bash
# Copy environment template (if provided)
cp .env.example .env

# Install dependencies (if applicable)
# npm install
# pip install -r requirements.txt

# Run tests
# npm test
# pytest
```

---

## Repository Structure

```
development-box/
├── .github/
│   ├── workflows/          # CI/CD GitHub Actions
│   └── ISSUE_TEMPLATE/     # Issue templates
├── src/                    # Source code
├── docs/                   # Documentation
├── tests/                  # Test files
├── .gitignore              # Files to ignore in git
├── .env.example            # Environment variables template
├── SECURITY.md             # Security policies
├── CODEOWNERS              # Code review automation
├── README.md               # This file
└── LICENSE                 # MIT License
```

---

## Security & Guardrails

### Access Control
- Repository is **PRIVATE** — authentication required
- Collaborators must be explicitly added
- All access is logged and auditable

### Branch Protection
- **`main` branch:**
  - Requires 1+ pull request review
  - All status checks must pass
  - Branches must be up to date
  - No force pushes allowed
  - Enforced for all including administrators

- **`develop` branch:**
  - Same protections as main
  - Used for feature integration

### Secret & Credential Security

**Never commit:**
- API keys or tokens
- Database passwords
- AWS/Azure/GCP credentials
- SSH or PGP private keys
- OAuth tokens
- Sensitive configuration

**Always use:**
- `.env` files (in `.gitignore`)
- GitHub Secrets for CI/CD
- Environment-specific configs
- Credential management tools

### Credential Rotation

| Type | Frequency | Next Rotation |
|---|---|---|
| Personal Access Token | 90 days | November 14, 2026 |
| SSH Keys | 180 days | February 14, 2027 |
| API Keys | 90 days | November 14, 2026 |

**See SECURITY.md for detailed policies.**

---

## Development Workflow

### 1. Create a Feature Branch

```bash
git checkout -b feature/your-feature-name
```

**Branch naming convention:**
- `feature/` — New features
- `bugfix/` — Bug fixes
- `chore/` — Maintenance/configuration
- `docs/` — Documentation
- `security/` — Security updates

### 2. Make Changes & Commit

```bash
git add .
git commit -m "feat: add clear description of changes"
```

**Commit message format:**
```
type(scope): subject

Body with detailed explanation (optional)
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`

### 3. Push & Create Pull Request

```bash
git push origin feature/your-feature-name
```

Then create a PR on GitHub with:
- Clear title and description
- Reference to related issues (if any)
- Screenshots (if UI changes)
- Test results

### 4. Code Review & Merge

- At least 1 review required
- All status checks must pass
- Reviewer approval required
- Branch auto-deletes after merge

---

## Collaboration Guidelines

### Code Review Standards
- ✅ Be respectful and constructive
- ✅ Provide specific feedback
- ✅ Suggest improvements, don't just critique
- ✅ Request changes clearly
- ✅ Approve only when satisfied

### Issue Tracking
- Use GitHub Issues for bugs and features
- Provide clear title and description
- Include reproduction steps (for bugs)
- Link related issues and PRs
- Assign to relevant team members

### Communication
- Respond to reviews within 24 hours
- Ask questions if feedback is unclear
- Discuss complex changes before implementation
- Use GitHub discussions for brainstorming

---

## Testing & Quality

### Before Submitting a PR
- ✅ Run local tests: `npm test` or `pytest`
- ✅ Check code formatting: `eslint` or `black`
- ✅ Verify linting passes
- ✅ Ensure documentation is updated
- ✅ Check for secrets with `git-secrets`

### CI/CD Pipeline
GitHub Actions automatically:
- Runs unit tests
- Performs security scanning
- Checks code formatting
- Validates build artifacts
- Scans for vulnerable dependencies

---

## Troubleshooting

### Reset a Branch to Latest Main
```bash
git fetch origin
git reset --hard origin/main
```

### Remove Accidentally Committed File
```bash
git rm --cached filename
echo "filename" >> .gitignore
git commit -m "chore: remove accidentally committed file"
git push
```

### Fix Leaked Secrets
1. Revoke the credential immediately
2. Use BFG Repo-Cleaner to remove from history
3. Generate new credential
4. Force push cleaned history

**See SECURITY.md for detailed incident response.**

---

## Support & Questions

**Repository Owner:** David Roderiques  
**Email:** droderiques.it@gmail.com

### Reporting Security Issues
⚠️ **Do NOT** create public GitHub issues for security vulnerabilities.

Email security concerns directly to droderiques.it@gmail.com with:
- Detailed description of vulnerability
- Steps to reproduce (if applicable)
- Potential impact
- Suggested fix (if any)

---

## License

This repository is licensed under the **MIT License** — see LICENSE file for details.

---

## Changelog

### v1.0.0 (2026-08-15)
- ✅ Initial repository setup
- ✅ Security policies implemented
- ✅ Branch protection configured
- ✅ CODEOWNERS file created
- ✅ Development guidelines established

---

**Last Updated:** August 15, 2026  
**Next Review:** September 15, 2026
