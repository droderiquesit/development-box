# AI Engineering DevBox

A portable engineering workstation in a container: Terraform, Kubernetes, cloud,
security and application tooling, plus a **governed** multi-provider AI platform.
Runs rootless under Podman. Attaches from VS Code.

```text
Windows / Linux / macOS host
        │
      Podman (rootless)
        │
        ▼
┌──────────────────────────────────────────────────────┐
│                AI ENGINEERING DEVBOX                 │
│                                                      │
│  Terraform · OpenTofu · Terragrunt · tflint          │
│  kubectl · Helm · Kustomize · k9s · Flux             │
│  Python 3.12 · Node 24 · Go 1.26                     │
│  git · gh · actionlint · shellcheck · yamllint       │
│  Trivy · gitleaks · semgrep · OPA · syft · cosign    │
│  AWS · Azure · GCP CLIs  (optional modules)          │
│                                                      │
│  ── AI PLATFORM ──────────────────────────────────   │
│  Claude Code · Codex · Gemini · LiteLLM router       │
│  model profiles · task routing · agent roles         │
│                                                      │
│  ── MCP LAYER ────────────────────────────────────   │
│  filesystem · git · github · fetch · terraform       │
│  context7 · time   (registry-controlled allowlist)   │
│                                                      │
│  ── GOVERNANCE ───────────────────────────────────   │
│  one canonical policy · command guardrails           │
│  MCP trust profiles · credential boundary · audit    │
└──────────────────────────────────────────────────────┘
        │
        ├─ Anthropic · OpenAI · Gemini
        ├─ Azure OpenAI · Bedrock · Vertex AI
        └─ local models (Ollama)
```

**Design principles:** reproducible · disposable container · persistent
workspace · secrets never in the image · least privilege · modular · observable
via `devbox doctor` · centrally governed · model-agnostic.

---

## Quick start

```bash
git clone https://github.com/droderiquesit/development-box.git
cd development-box

make build            # pulls the published base release, builds the devbox
podman compose up -d

podman exec -it ai-devbox bash -l
devbox doctor
```

Then in VS Code: **Dev Containers: Attach to Running Container** → `ai-devbox`.

---

## Prerequisites

| | Minimum | Notes |
|---|---|---|
| Podman | 4.0+ | Rootless. Docker Desktop is **not** required and not used. |
| podman-compose *or* Docker Compose v2 | any recent | Only for `compose.yaml`; `make run` works without it. |
| VS Code | any recent | With the **Dev Containers** extension. |
| Disk | ~12 GB | Base ~1.7 GB, DevBox ~4 GB, plus caches. |
| RAM | 4 GB | 16 GB+ if you run local models. |

### Podman setup

<details>
<summary><b>Linux</b></summary>

```bash
sudo apt install podman podman-compose        # Debian/Ubuntu
sudo dnf install podman podman-compose        # Fedora/RHEL

# Rootless requires subuid/subgid ranges — usually already set
grep "$USER" /etc/subuid /etc/subgid || \
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"

podman system migrate
podman info | grep -A2 rootless
```

</details>

<details>
<summary><b>Windows (WSL2)</b></summary>

```powershell
winget install RedHat.Podman
podman machine init --cpus 4 --memory 8192 --disk-size 100
podman machine start
podman info
```

Keep your repositories **inside** the WSL2 filesystem (`\\wsl$\...`), not on
`C:\`. Cross-filesystem I/O through `/mnt/c` is roughly an order of magnitude
slower, and `terraform init` will feel it.
</details>

<details>
<summary><b>macOS</b></summary>

```bash
brew install podman podman-compose
podman machine init --cpus 4 --memory 8192 --disk-size 100
podman machine start
```

</details>

---

## Installation

The base image (OS, non-root user, Go/Node/Python + uv) is an external
dependency — a published, signed release of the [Base Image
Factory](https://github.com/droderiquesit/ai-devbox), pinned by
repo + version + digest in `versions.yaml`. It is pulled, never built here.

```bash
# 1 — pull the pinned base release, then build the devbox image (~4 min).
make build

# rebuild just the devbox layer (the common case)
make rebuild

# with optional modules
make build-devbox FEATURE_CLOUD_AWS=1 FEATURE_CLOUD_AZURE=1
```

| Build arg | Default | What it adds |
|---|---|---|
| `FEATURE_CLOUD_AWS` | 0 | AWS CLI v2 (GPG-verified) |
| `FEATURE_CLOUD_AZURE` | 0 | Azure CLI |
| `FEATURE_CLOUD_GCP` | 0 | gcloud + GKE auth plugin |
| `FEATURE_K8S_LOCAL` | 0 | kind (needs a container socket — read [decisions.md](docs/decisions.md) first) |
| `FEATURE_AI_GEMINI` | 1 | Gemini CLI |
| `FEATURE_AI_EXTRA` | 0 | Aider + OpenCode |
| `FEATURE_MCP_BROWSER` | 0 | Playwright MCP server |
| `FEATURE_MCP_KUBERNETES` | 0 | Kubernetes MCP server |
| `FEATURE_ANSIBLE` | 0 | ansible-lint |
| `FEATURE_SUDO` | 1 | sudo inside the container |

**Behind a TLS-inspecting corporate proxy?** Drop your root CA as a `.crt` into
`config/ca-certificates/` before building. Both images pick it up, and every
`apt`, `curl`, `go install`, `npm` and `uv` inside the build will trust it.

---

## VS Code

Two supported ways in.

### Attach to a running container (recommended for a long-lived box)

```bash
podman compose up -d
```

Then: **Dev Containers: Attach to Running Container** → `ai-devbox`.

### Reopen in container (recommended on a fresh machine)

**Dev Containers: Reopen in Container** — VS Code builds and starts the stack
from `.devcontainer/devcontainer.json`.

Either way, set Podman as the runtime once (already in `.vscode/settings.json`
for this repo, but you want it in your user settings too):

```jsonc
{
  "dev.containers.dockerPath": "podman",
  "dev.containers.dockerComposePath": "podman-compose"
}
```

Included: Terraform/OpenTofu with `terraform-ls`, Python with Ruff,
Go, YAML with schema validation, Kubernetes, Helm, GitHub Actions, GitLens,
shellcheck, Markdown with Mermaid, and Claude Code. Format-on-save is on for
every language with a canonical formatter.

`.vscode/tasks.json` mirrors the `devbox` CLI exactly — nothing in the palette
does something you cannot do in a terminal.

---

## Authentication

**Nothing is ever baked into the image.** A build-time assertion fails the build
if a credential directory appears, and `tests/run.sh secrets` re-checks the
shipped image.

### AI providers

```bash
export ANTHROPIC_API_KEY="..."
export OPENAI_API_KEY="..."
export GEMINI_API_KEY="..."
podman compose up -d
```

Or a gitignored `.env` next to `compose.yaml`.

Check what is wired up — presence only, values are never read:

```bash
ai providers
```

### GitHub

Use a **fine-grained** PAT scoped to exactly `contents: read`,
`pull_requests: write`, `issues: read`, `actions: read`, `metadata: read`:

```bash
export GITHUB_PERSONAL_ACCESS_TOKEN="github_pat_..."
```

Or authenticate interactively — `gh auth login` inside the box persists to the
config volume.

### Cloud

Preference order, best first:

1. **OIDC / workload identity / SSO.** Nothing to mount, nothing to leak.

   ```bash
   export AWS_PROFILE=dev-sso        # session expires on its own
   ```

2. **Environment injection** for a short-lived token.
3. **Read-only mounts** — commented out in `compose.yaml`. Uncomment only what
   you need, and keep `:ro`:

   ```yaml
   # - ${HOME}/.aws:/home/dev/.aws:ro
   ```

---

## Daily use

### Health

```bash
devbox doctor              # full check
devbox doctor --core-only  # fast
devbox doctor --json       # machine readable
devbox status              # one screen
devbox versions            # pinned vs installed
devbox info                # config locations and feature flags
```

### Terraform

```bash
devbox terraform check     # fmt · validate · tflint · security · policy · docs
devbox terraform fmt
devbox terraform validate
devbox terraform security  # checkov + trivy config
devbox terraform docs --check
```

`check` is entirely read-only: no backend init, no plan, no apply. There is
deliberately no alias, task or command anywhere in this repo that runs
`terraform apply` — see [security.md](docs/security.md).

Aliases: `tf` `tg` `tf-init` `tf-plan` `tf-fmt` `tf-validate` `tf-check`.

The provider cache is a named volume, so `terraform init` in a fresh container
does not re-download hundreds of megabytes.

### GitHub

```bash
devbox github check        # actionlint + yamllint + shellcheck + SHA pinning
gh pr create               # gh works normally
```

The pinning check flags any third-party action pinned to a mutable tag rather
than a commit SHA.

### Kubernetes

```bash
k get pods                 # alias for kubectl
k9s
stern my-app
kubectx / kubens
```

Your kubeconfig is **not** mounted by default. Mount it read-only and prefer a
context bound to a `view` ClusterRole.

### Security

```bash
devbox security scan
devbox security scan --scope secrets
devbox security scan --format json
devbox security sbom --sign
```

---

## AI

```bash
ai models                          # queried live — nothing hardcoded
ai use claude | codex | gemini | local
ai profile fast | balanced | deep | terraform | secure | code-review
ai ask "explain this repository"
ai review terraform
ai review github-actions
ai security
ai architecture
ai compare claude codex "is this module correct?"
ai run terraform-review            # bounded workflow, ends at a human
ai prompt                          # the prompt library
ai agent terraform-agent
```

`claude`, `codex` and `gemini` remain fully available and unwrapped — `ai` adds
consistency, it never hides a native tool.

### Model profiles

`fast` · `balanced` (default) · `deep` · `local` · `secure` · `architecture` ·
`terraform` · `code-review`. Each controls provider, model, allowed tools, MCP
access, write permissions and command-execution policy. The active profile is in
your shell prompt.

### Local models

```bash
export OLLAMA_BASE_URL=http://host.containers.internal:11434   # host Ollama
ai use local

# or run it as a sidecar
podman compose --profile local-ai up -d
```

The model runtime deliberately stays out of the development container.

Full detail: **[docs/ai.md](docs/ai.md)**.

---

## MCP

```bash
mcp list
mcp status
mcp enable context7
mcp disable memory
mcp profile READ_ONLY | DEVELOPER | PRIVILEGED
mcp doctor
mcp audit
```

The registry is an **allowlist**; the effective permission is
`registry ∩ trust profile ∩ security policy`. Default trust is `READ_ONLY`.
`PRIVILEGED` requires confirmation and auto-reverts after 60 minutes.

Full detail: **[docs/mcp.md](docs/mcp.md)**.

---

## Governance

One canonical policy in `ai/policies/policy.yaml` drives everything:

| Class | Behaviour |
|---|---|
| `SAFE` | Runs without asking — plans, validators, linters, read-only queries |
| `REVIEW_REQUIRED` | Runs; result shown before continuing |
| `APPROVAL_REQUIRED` | A human approves — `terraform apply`, `git push`, `kubectl apply`, all cloud mutation |
| `BLOCKED` | Never, even with approval — `terraform destroy`, `kubectl delete`, `rm -rf /`, `git push --force`, `git reset --hard` |

Anything unmatched defaults to `APPROVAL_REQUIRED`.

Client instruction files (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`,
`.github/copilot-instructions.md`, `.cursor/rules/`) are **generated**:

```bash
ai sync            # regenerate
ai sync --check    # fails CI and pre-commit on drift
```

Full detail: **[docs/security.md](docs/security.md)**.

---

## Persistence

The container is disposable. These survive `podman compose down && up`:

| Volume | Contents |
|---|---|
| bind mount | `/workspace` — your code |
| `devbox-config` | `~/.config` — your DevBox configuration |
| `devbox-state` | `~/.local/state` — active profiles, audit log |
| `tf-plugin-cache` | Terraform providers |
| `go-cache`, `npm-cache`, `uv-cache`, `pip-cache`, `helm-cache`, `trivy-cache` | build and scanner caches |
| `devbox-history` | shell history |

```bash
podman compose down       # keeps volumes
make clean-all            # deletes volumes — prompts first
```

---

## Updates

`versions.yaml` is the single source of truth. Renovate opens PRs against it and
nothing else. Security scanners get a fast lane; major bumps are never
auto-merged.

```bash
devbox versions           # pinned vs installed
devbox update ai          # refresh the channel-pinned AI CLIs
make build-devbox         # ~4 minutes
```

---

## Testing

```bash
make lint                 # shellcheck + yamllint + actionlint
make validate             # config validation, no build required
make test                 # full image contract suite
tests/run.sh guardrails   # just the guardrail assertions
```

The suite tests the image's **contract**, not its implementation: every promised
tool runs, the container is non-root, the guardrails actually block what they
claim, and no credentials are baked in. That is what stops this README from
quietly becoming fiction.

---

## Troubleshooting

Common ones; the rest is in
**[docs/troubleshooting.md](docs/troubleshooting.md)**.

| Symptom | Fix |
|---|---|
| Files owned by root in the container | Add `--userns=keep-id` (already in `.devcontainer/devcontainer.json`) |
| `dubious ownership` from git | The entrypoint adds `/workspace` to `safe.directory`; run it or add manually |
| Permission denied on a bind mount (SELinux) | Use `:z` on the volume — already set in `compose.yaml` |
| Certificate errors during build | Corporate TLS proxy — put its root CA in `config/ca-certificates/` |
| VS Code cannot find the container | Set `dev.containers.dockerPath` to `podman` |
| `terraform init` re-downloads providers | Check `devbox doctor` reports the plugin cache as a mount |

---

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System design, the decisions that shaped it, diagrams |
| [docs/ai.md](docs/ai.md) | Providers, routing, profiles, workflows, agent roles |
| [docs/mcp.md](docs/mcp.md) | Registry, trust profiles, scoping, threat model |
| [docs/security.md](docs/security.md) | Guardrails, secrets, hardening, supply chain, limitations |
| [docs/releases.md](docs/releases.md) | Version streams, base patching, the tag ladder, build caching |
| [docs/automation.md](docs/automation.md) | The automated rebuild chain: factory dispatch, daily reconciler, rollback |
| [docs/decisions.md](docs/decisions.md) | Every tool, classified with a reason |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Podman, VS Code, Terraform, AI, MCP |

---

## Licence

MIT — see [LICENSE](LICENSE).
