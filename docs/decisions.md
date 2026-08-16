# Tool decisions

Every tool is classified `REQUIRED`, `RECOMMENDED`, `OPTIONAL` or `REJECTED`
with a reason, per §44. The purpose is not bureaucracy — it is so that "should
we add X?" has an answer six months from now, and so that nobody installs five
tools that solve the same problem.

**The general rule:** a tool earns its place by covering a surface nothing else
covers. Two tools reporting the same finding is a cost with no benefit —
duplicate output trains people to skim.

---

## Legend

| | Meaning |
|---|---|
| **REQUIRED** | The box is broken without it. Always installed. |
| **RECOMMENDED** | Installed by default; genuinely improves daily work. |
| **OPTIONAL** | Behind a `FEATURE_*` build arg. Real value, real cost. |
| **REJECTED** | Considered and declined. The reason is the important part. |

---

## Base image and platform

| Choice | Verdict | Reason |
|---|---|---|
| Ubuntu 24.04 LTS | REQUIRED | Every vendor this box depends on (HashiCorp, Microsoft, Google, GitHub, Aqua, NodeSource) publishes a `noble` apt repo. Supported to 2029. |
| Debian trixie | REJECTED | Patchier vendor apt coverage. A missing vendor repo means an unverified tarball, which is what we are avoiding. |
| Alpine | REJECTED | musl breaks a long tail of prebuilt binaries and Python wheels. A dev container is not where you debug musl-vs-glibc. |
| Distroless | REJECTED | This container's entire purpose is to run a shell. |
| Podman (rootless) | REQUIRED | Explicit requirement, and the right default: no daemon, no Docker Desktop licence, rootless by design. |
| Two images (base + devbox) | REQUIRED | 4-minute rebuilds instead of 25. A CVE in an AI CLI must not force a Go toolchain rebuild. |

---

## Acquisition strategy

| Method | Verdict | Reason |
|---|---|---|
| Signed apt repositories | REQUIRED | Strongest verification available: GPG-signed, `signed-by=` keyring, no `apt-key`. Used for Terraform, OpenTofu, gh, Trivy, Node, Azure CLI, gcloud. |
| `go install` at a pinned version | REQUIRED | Verified end-to-end by the Go checksum database. One pin per tool instead of a SHA-256 table per tool per arch. Covers 18 tools. |
| Release artefact + published SHA-256 | REQUIRED | For the three tools whose `go.mod` has `replace` directives (terragrunt, infracost, flux), which Go refuses to `go install` by design. |
| Vendor tarball + published checksum | REQUIRED | kubectl (`dl.k8s.io/.sha256`), Helm (`get.helm.sh/.sha256sum`), Go itself (`go.dev` signed index). |
| GPG-verified installer | REQUIRED | AWS CLI v2, with the signing key's fingerprint pinned in the install script. |
| `curl \| bash` | **REJECTED** | Unverifiable by construction. Enforced by `security/policy/container/image.rego` — the build fails if one appears. |
| Unpinned `latest` | REJECTED | Except for the AI CLIs, where it is deliberate and documented (they ship several releases per week; an exact pin is stale in days). |

---

## Infrastructure as code

| Tool | Verdict | Reason |
|---|---|---|
| terraform | REQUIRED | The industry default. |
| opentofu | REQUIRED | Drop-in fork; many orgs run both. A devbox that forces the choice is the wrong tool. |
| terragrunt | RECOMMENDED | DRY multi-environment root modules. |
| terraform-ls | REQUIRED | Powers the VS Code Terraform extension. Without it the editor experience is a text editor. |
| tflint | REQUIRED | Provider-aware linting that `terraform validate` cannot do. |
| terraform-docs | RECOMMENDED | Generated module docs; a hand-written variable table is stale in a week. |
| checkov | REQUIRED | IaC policy depth. Also covers Helm, Kubernetes and Dockerfiles. |
| infracost | RECOMMENDED | Cost delta on a plan; drives the `cost-agent`. |
| OPA + conftest | REQUIRED | Rego is the portable way to express org-specific policy. `opa` for unit-testing the policies, `conftest` for applying them. |
| **tfsec** | **REJECTED** | Merged upstream into Trivy, which is installed. Would be a duplicate scanner reporting duplicate findings. |
| **terraformer** | REJECTED | Import/reverse-engineering tool. Occasional need, large surface. Install per project. |
| **terratest** | REJECTED | A Go library, not a CLI. Belongs in the project's `go.mod`. |

---

## Kubernetes and GitOps

| Tool | Verdict | Reason |
|---|---|---|
| kubectl | REQUIRED | — |
| helm | REQUIRED | — |
| kustomize | REQUIRED | The standalone binary is still needed for `kustomize build` outside kubectl's vendored copy. |
| k9s | RECOMMENDED | The single highest-leverage cluster debugging TUI. |
| stern | RECOMMENDED | Multi-pod log tailing. `kubectl logs` cannot do it. |
| kubectx / kubens | RECOMMENDED | Context and namespace switching. Prevents the "wrong cluster" incident. |
| flux | RECOMMENDED | GitOps CLI only; installs nothing into a cluster. |
| **argocd CLI** | OPTIONAL | `FEATURE_GITOPS_ARGO`. Not both by default — install the GitOps engine you actually run. Two engines is two ways to do one job. |
| **kind** | OPTIONAL | `FEATURE_K8S_LOCAL`. Needs a container runtime socket inside the DevBox. Works with rootless Podman, but the socket is a real widening of the container's reach. Off by default; enable deliberately. |
| **k3d** | **REJECTED** | Duplicates kind and specifically requires a Docker socket. kind speaks Podman natively. |
| **minikube** | REJECTED | Heavier than kind for the same job; assumes a VM driver. |
| **kubeseal / SOPS** | REJECTED from the image | Project-specific and key-bound. `kubernetes-agent` recommends them; installing them without keys achieves nothing. |

---

## Security and supply chain

| Tool | Verdict | Reason |
|---|---|---|
| trivy | REQUIRED | One scanner covering IaC misconfig, container CVEs, filesystem CVEs, secrets and SBOM. Absorbed tfsec. |
| gitleaks | REQUIRED | Git-**history** secret detection. Trivy scans a tree; a secret removed in a later commit is still compromised. |
| checkov | REQUIRED | IaC policy depth Trivy's config scanner does not reach. Genuinely different rule sets, not duplication. |
| semgrep | RECOMMENDED | Cross-language SAST — the one thing Trivy does not do. Run with `p/ci`, the curated low-false-positive ruleset. |
| OPA + conftest | REQUIRED | See above. |
| syft | REQUIRED | SBOM generation, SPDX + CycloneDX. |
| grype | REQUIRED | Scans the SBOM rather than re-walking the filesystem. Composes with syft by design. |
| cosign | RECOMMENDED | Keyless (OIDC) signing and attestation — no signing key to store, rotate or leak. |
| shellcheck / yamllint / actionlint | REQUIRED | Each owns a surface nothing else covers. |
| **snyk** | **REJECTED** | Commercial licence and telemetry; overlaps Trivy and Grype entirely. |
| **tfsec** | **REJECTED** | Upstream-merged into Trivy. |
| **A fourth CVE scanner** | REJECTED | Overlapping findings, no additional signal, and duplicate output trains people to skim. |

**Why exactly one owner per surface:** secrets-in-history → gitleaks;
IaC misconfig → checkov + trivy config (different rulesets, both justified);
dependency CVEs → trivy fs / grype; SAST → semgrep; shell → shellcheck;
workflows → actionlint; org policy → OPA.

---

## Languages and runtimes

| Choice | Verdict | Reason |
|---|---|---|
| Python 3.12 (system) | REQUIRED | Ubuntu LTS-supported to 2029. `uv` provides per-project interpreters when a project needs another — that is where a version manager earns its keep, not in the image. |
| Node 24 LTS via NodeSource | REQUIRED | Signed apt repo. Chosen over nvm: no per-shell shim, no runtime download. |
| Go 1.26 tarball | REQUIRED | Official, checksum-verified against go.dev's signed index. |
| uv | REQUIRED | Every Python CLI gets its own isolated environment, so checkov's pinned urllib3 cannot fight semgrep's. |
| pipx | RECOMMENDED | Several ecosystems still document `pipx install`. Shares uv's venv rather than getting its own. |
| pnpm via corepack | RECOMMENDED | Ships with Node; no second installer. |
| **nvm / pyenv / rbenv** | **REJECTED** | Per-shell shims make the image fragile and slow every shell start. `uv` covers the one case that matters. |
| **asdf / mise** | REJECTED | Genuinely good tools, but they move version management from the image into a runtime resolver — which defeats the point of a reproducible image. |
| **rustup** | REJECTED | ~1.5 GB toolchain for a box whose Rust needs are `just` and `ripgrep`, both available prebuilt. |

---

## Developer tooling

| Tool | Verdict | Reason |
|---|---|---|
| git, gh | REQUIRED | — |
| jq, yq | REQUIRED | JSON and YAML are the lingua franca here. |
| ripgrep, fd, fzf, bat, tree | RECOMMENDED | Each removes a real papercut. |
| just | RECOMMENDED | From the Ubuntu archive, avoiding a Rust toolchain. |
| task | RECOMMENDED | Cross-platform task runner; better `--list` than Make. Both exist because both are genuinely used, and they delegate to the same scripts so they cannot drift. |
| tmux | RECOMMENDED | Sessions survive a dropped connection. |
| direnv | RECOMMENDED | Per-project environment without polluting the shell. |
| lazygit | OPTIONAL | `FEATURE_EXTRA_TUI=1` (on by default). Fast staging and rebase. |
| pre-commit | REQUIRED | The local gate that mirrors CI. |
| **act** (local Actions runner) | **REJECTED** | Needs a container socket inside the DevBox, and its runner images drift from GitHub-hosted ones often enough to produce false confidence. `actionlint` for static errors plus a real `gh workflow run` on a throwaway branch is cheaper and more truthful. Revisit if you move to self-hosted runners built from this image. |
| **oh-my-zsh / starship** | REJECTED | Startup latency and an external dependency for something a 40-line prompt function does. The shell config here shows git branch, kube context and AI profile with no framework. |
| **A hundred aliases** | REJECTED | §25 asks for a handful you will actually use. Everything destructive is left as the real command so it never fires by muscle memory. |

---

## Cloud CLIs

All three are `OPTIONAL` (`FEATURE_CLOUD_AWS` / `_AZURE` / `_GCP`, default off).

Together they add roughly 1.5 GB, and almost nobody needs all three on the same
day. Enable what you use:

```bash
make build-devbox FEATURE_CLOUD_AWS=1
```

Credentials are never baked in. Telemetry is disabled where the vendor allows —
an engineering workstation handling infrastructure code should not phone home
about every command.

---

## AI tooling

See [ai.md](ai.md#tool-selection--what-was-installed-and-why) for the full table.
Summary: Claude Code and Codex REQUIRED (different model families, and the
review workflows depend on them disagreeing), Gemini CLI and `llm` RECOMMENDED,
LiteLLM REQUIRED as the provider abstraction, Aider and OpenCode OPTIONAL
(overlap), Continue and Cline REJECTED (they are VS Code extensions, not CLIs —
installing them into the image is a category error).

---

## MCP servers

See [mcp.md](mcp.md#the-registry). Summary: seven enabled by default, all
official or widely adopted; five available but off; shell-execution servers,
demo servers, write-capable database servers and community aggregator bundles
rejected outright.

---

## VS Code extensions

| Rejected | Reason |
|---|---|
| `ms-python.flake8`, `ms-python.isort`, `ms-python.black-formatter` | Superseded by `charliermarsh.ruff`, which does lint + import sort + format in one fast binary. Running all three fights over format-on-save. |
| `ms-azuretools.vscode-docker` | Superseded by `ms-azuretools.vscode-containers`, which is Podman-aware. |
| A fourth AI assistant extension | Each one adds a context menu, a keybinding conflict and a background process. Two is already generous. |

Listed in `.vscode/extensions.json` under `unwantedRecommendations` so VS Code
actively suggests removing them.

---

## Things deliberately not built

| | Reason |
|---|---|
| A custom agent framework | Claude Code and Codex already implement agentic loops with permission systems. `ai run` is ~120 lines of bash that sequences declared steps and enforces limits. |
| A database, API server or queue | Configuration is YAML; state is files. If this needed a database, the design would be wrong. |
| Microservices | Three containers, two optional. The router is separate because it has different credentials and lifecycle; the model runtime because it is enormous. Neither for appearance. |
| A web UI | The terminal and VS Code are the interface. |
| A plugin system | YAML config plus small scripts covers every extension point anyone has actually wanted. |
