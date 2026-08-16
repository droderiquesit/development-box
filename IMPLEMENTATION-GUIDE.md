# Development-Box Repository Implementation Guide

**Date:** August 15, 2026  
**Owner:** David Roderiques (droderiques.it@gmail.com)  
**Repository:** development-box

---

## Complete Setup Guide

This document provides **3 implementation options** to create and secure your `development-box` repository with comprehensive guardrails.

---

## 🚀 Option 1: GitHub CLI (Recommended - Fastest)

### Prerequisites
- GitHub CLI installed: `brew install gh` (macOS) or `choco install gh` (Windows)
- GitHub token ready (provided)

### Step-by-Step

**Step 1: Set Environment Variable**
```bash
export GITHUB_TOKEN="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"
```

**Step 2: Navigate to Your Project Directory**
```bash
cd /path/to/development-box
```

**Step 3: Initialize Git (if not already done)**
```bash
git init
git add .
git commit -m "Initial commit with security guardrails"
```

**Step 4: Create Repository**
```bash
gh repo create development-box \
  --private \
  --description "Development environment repository (droderiques.it@gmail.com) - Secure workspace with security guardrails" \
  --source=. \
  --remote=origin \
  --push
```

**Step 5: Verify Creation**
```bash
gh repo view droderiquesit/development-box
```

**Output should show:**
```
✓ Repository created successfully
  Name: development-box
  Visibility: Private
  Owner: droderiquesit
  URL: https://github.com/droderiquesit/development-box
```

### Post-Creation Security Configuration

```bash
# Configure auto-merge settings
gh repo edit droderiquesit/development-box \
  --enable-auto-merge \
  --enable-delete-branch-on-merge \
  --enable-squash-merge
```

**Estimated Time:** 3-5 minutes

---

## 📝 Option 2: Manual GitHub.com Setup

### Step-by-Step

**Step 1: Go to GitHub**
- Open: https://github.com/new

**Step 2: Configure Repository**
```
Repository name:        development-box
Description:            Development environment repository (droderiques.it@gmail.com) - Secure workspace with security guardrails
Visibility:             Private ✓
Initialize with:        Add a README file
Add .gitignore:         None (we'll add manually)
Choose license:         MIT License
```

**Step 3: Create Repository**
- Click "Create repository"

**Step 4: Clone to Local Machine**
```bash
git clone git@github.com:droderiquesit/development-box.git
cd development-box
```

**Step 5: Add Security Files**
Copy these files to your local repo:
- `.gitignore`
- `SECURITY.md`
- `CODEOWNERS`
- `README.md`
- `LICENSE`

**Step 6: Commit and Push**
```bash
git add .
git commit -m "chore: add security guardrails and documentation"
git push origin main
```

**Step 7: Configure Branch Protection (GitHub Web UI)**

**For `main` branch:**
1. Go to Settings → Branches
2. Add branch protection rule for `main`
3. Configure:
   - ✅ Require a pull request before merging
   - ✅ Dismiss stale pull request approvals
   - ✅ Require status checks to pass before merging
   - ✅ Require branches to be up to date before merging
   - ✅ Restrict who can push to matching branches
   - ✅ Enforce all above rules for administrators

**For `develop` branch:**
1. Add another branch protection rule for `develop`
2. Use same settings as `main`

**Estimated Time:** 10-15 minutes

---

## 🔧 Option 3: GitHub API (Advanced)

### Prerequisites
- GitHub CLI installed
- API familiarity
- Token with `repo` scope

### Step-by-Step

**Step 1: Create Repository via API**
```bash
curl -X POST https://api.github.com/user/repos \
  -H "Authorization: token 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" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "development-box",
    "description": "Development environment repository (droderiques.it@gmail.com) - Secure workspace with security guardrails",
    "private": true,
    "auto_init": true,
    "license_template": "mit"
  }'
```

**Step 2: Add Branch Protection**
```bash
curl -X PUT https://api.github.com/repos/droderiquesit/development-box/branches/main/protection \
  -H "Authorization: token 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" \
  -H "Content-Type: application/json" \
  -d '{
    "required_status_checks": {
      "strict": true,
      "contexts": []
    },
    "enforce_admins": true,
    "required_pull_request_reviews": {
      "dismiss_stale_reviews": true,
      "require_code_owner_reviews": true,
      "required_approving_review_count": 1
    },
    "restrictions": null
  }'
```

**Step 3: Add CODEOWNERS File**
```bash
curl -X PUT https://api.github.com/repos/droderiquesit/development-box/contents/.github/CODEOWNERS \
  -H "Authorization: token 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" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "chore: add CODEOWNERS file",
    "content": "* @droderiquesit"
  }'
```

**Estimated Time:** 5-10 minutes (requires API knowledge)

---

## ✅ Post-Setup Verification Checklist

After choosing any option above, verify:

- [ ] Repository created and visible at: https://github.com/droderiquesit/development-box
- [ ] Repository is **PRIVATE**
- [ ] `main` branch has branch protection enabled
- [ ] `develop` branch has branch protection enabled
- [ ] `.gitignore` prevents secrets from being committed
- [ ] `SECURITY.md` is present and accessible
- [ ] `CODEOWNERS` file is configured
- [ ] `README.md` documents the project
- [ ] `LICENSE` file is included (MIT)
- [ ] All files are committed and pushed

---

## 🔐 Security Configuration Checklist

### Repository Settings
- [ ] Visibility set to Private
- [ ] Require pull request reviews enabled
- [ ] Status checks required before merge
- [ ] Branches up to date requirement enabled
- [ ] Enforce admin rules enabled
- [ ] Auto-delete head branches on merge enabled
- [ ] Allow auto-merge enabled

### Access Control
- [ ] Only owner has repository access
- [ ] No public collaborators added
- [ ] SSH keys verified and secure
- [ ] Two-factor authentication enabled on GitHub account

### Secrets & Credentials
- [ ] `.env` file in `.gitignore`
- [ ] No API keys in `.env.example`
- [ ] No credentials in README or documentation
- [ ] `.env.example` template created (if applicable)

### Branch Protection
- [ ] CODEOWNERS file configured
- [ ] Branch protection on `main` enforced
- [ ] Branch protection on `develop` enforced
- [ ] Admin enforcement enabled for both branches

---

## 🚨 Token Revocation (CRITICAL - DO THIS IMMEDIATELY)

**After successfully creating the repository:**

1. **Go to GitHub:** https://github.com/settings/tokens

2. **Find the token:** `development-box-setup` or your token name

3. **Click "Delete"** to revoke it

4. **Confirm deletion**

5. **Verify** it's no longer in the list

⚠️ **This is essential for security — the token should only be used once.**

---

## 📋 Branch Workflow Setup

### Create Branches

**Development branch:**
```bash
git checkout -b develop
git push -u origin develop
```

**Feature branch template:**
```bash
git checkout -b feature/your-feature-name
# Make changes
git add .
git commit -m "feat: description of feature"
git push -u origin feature/your-feature-name
# Create Pull Request on GitHub
```

---

## 📖 Documentation Created

The following files have been created and are ready to push:

| File | Purpose |
|------|---------|
| `README.md` | Project overview, setup, and guidelines |
| `SECURITY.md` | Comprehensive security policies |
| `CODEOWNERS` | Automatic code review assignment |
| `.gitignore` | Prevent accidental commits of secrets |
| `LICENSE` | MIT License |
| `development-box-setup.sh` | Automated setup script |

---

## 🎯 Next Steps

1. **Choose your implementation option** (1, 2, or 3)
2. **Execute the setup** step-by-step
3. **Verify** with the checklist
4. **Revoke the token** immediately
5. **Start developing** with confidence

---

## ❓ Troubleshooting

### "fatal: not a git repository"
```bash
git init
```

### "Authentication failed"
- Check token is correctly set in environment
- Verify token hasn't been revoked
- Generate new token if needed

### "Branch protection not applying"
- Wait a few seconds for GitHub to sync
- Refresh the page
- Check if you're on the correct repository

### "Repository already exists"
```bash
# If repo exists locally, update remote
git remote set-url origin https://github.com/droderiquesit/development-box.git
git push -u origin main
```

---

## 📞 Support

**Repository Owner:** David Roderiques  
**Email:** droderiques.it@gmail.com

For questions about:
- Security policies → See `SECURITY.md`
- Development workflow → See `README.md`
- Code review standards → See `CODEOWNERS`

---

## 🎉 Summary

You now have a **production-ready, secure development repository** with:

✅ Private visibility  
✅ Branch protection and code review enforcement  
✅ Comprehensive security policies  
✅ Automated CODEOWNERS review  
✅ Proper `.gitignore` to prevent secret leaks  
✅ MIT License  
✅ Complete documentation  

**Time to get started: Choose an option and execute in 5-15 minutes.**

---

**Last Updated:** August 15, 2026
