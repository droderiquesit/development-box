# Troubleshooting

Start here:

```bash
devbox doctor            # what is actually broken
devbox doctor --json     # same, machine readable
devbox info              # where every config file is
mcp doctor               # MCP configuration conformance
ai doctor                # AI clients, providers, router, local models
```

---

## Podman

### `Error: short-name did not resolve to an alias`

Podman requires fully-qualified image names, unlike Docker.

```bash
podman pull docker.io/library/ubuntu:24.04     # not just "ubuntu:24.04"
```

The Containerfiles here already use fully-qualified names.

### Rootless: `newuidmap: write to uid_map failed`

Your user has no subuid/subgid range.

```bash
grep "$USER" /etc/subuid /etc/subgid
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate      # required after changing the ranges
```

### Files in `/workspace` are owned by root

Missing user-namespace mapping. Without it, container uid 1000 maps to a
different host uid and every file looks foreign.

```bash
podman run --userns=keep-id ...
```

Already set in `.devcontainer/devcontainer.json` and `make run`. For a
hand-rolled `podman run`, add it.

### `Permission denied` on a bind mount, SELinux host

SELinux blocks container access to unlabelled host files.

```bash
podman run -v "$PWD":/workspace:z ...   # :z shared, :Z private
```

`compose.yaml` already uses `:z`. If you are still blocked:

```bash
ls -Z /path/to/repo
sudo chcon -Rt container_file_t /path/to/repo   # persistent alternative
```

### `podman compose` does nothing useful

Podman delegates to whichever compose provider is installed.

```bash
podman compose version
pip install --user podman-compose        # or install Docker Compose v2
```

`make run` works without any compose provider at all.

### Windows: everything is slow

Your repository is on the Windows filesystem, reached through `/mnt/c`.

```bash
# inside WSL2
mkdir -p ~/src && cd ~/src
git clone <repo>
```

Cross-filesystem I/O through `/mnt/c` is roughly an order of magnitude slower.
`terraform init` and `npm install` feel it immediately.

### `no space left on device`

```bash
podman system df
podman system prune -a          # removes unused images and build cache
podman volume ls                # check nothing important is dangling
```

On macOS/Windows the Podman machine has its own disk:

```bash
podman machine stop
podman machine set --disk-size 120
podman machine start
```

---

## Build

### Certificate errors during the build

You are behind a TLS-inspecting corporate proxy. Every `apt`, `curl`,
`go install`, `npm` and `uv` inside the build will fail with an opaque
certificate error until the proxy's root CA is trusted.

```bash
cp /path/to/corporate-root-ca.crt config/ca-certificates/
make build
```

Both images install anything in that directory into the system trust store.
This is the intended mechanism, not a workaround.

### `E: Failed to fetch ... 405 Method Not Allowed`

Your proxy forwards `CONNECT` (HTTPS) but rejects plain HTTP. The build switches
the Ubuntu archive to HTTPS automatically once a trust store exists — which
requires the CA above. If your mirror is HTTP-only, opt out:

```bash
make build-base APT_USE_HTTPS=0
```

### `go install` fails with "contains one or more replace directives"

Expected for terragrunt, infracost and flux. Go refuses `go install` for modules
with `replace` directives by design. Those three are installed from
checksum-verified release artefacts in `scripts/install/26-release-tools.sh`.

If you add a new Go tool and hit this, move it to that script rather than
working around the check — the check is Go protecting the supply chain.

### `checksum mismatch`

The install aborts, correctly. Either the version in `versions.yaml` is wrong,
or something rewrote the download in flight.

```bash
grep -n '<tool>' versions.yaml
curl -sSL https://.../SHA256SUMS | grep <asset>
```

Never "fix" this by removing the verification.

### The build is very slow the first time

The builder stage compiles ~18 Go tools. Expect 15–25 minutes on 4 cores for a
cold build. Subsequent DevBox rebuilds reuse the cached builder stage and take
~4 minutes — that is the whole reason the images are split.

---

## VS Code

### Dev Containers cannot find the container

```jsonc
// settings.json
{
  "dev.containers.dockerPath": "podman",
  "dev.containers.dockerComposePath": "podman-compose"
}
```

Then reload the window. This is the single most common VS Code + Podman issue.

### "Reopen in Container" rebuilds every time

You have `shutdownAction` set to stop or remove. This repo sets `"none"` on
purpose — rebuilding a devbox because you closed a tab is the fastest way to
stop using one.

### Extensions do not install

Rootless containers with restricted capabilities can trip the extension host.

```bash
podman logs ai-devbox
podman exec -it ai-devbox bash -lc 'ls -la ~/.vscode-server'
```

If `~/.vscode-server` is not writable, the container user does not own its home
directory — check `--userns=keep-id`.

### `terraform-ls` does not start

```bash
podman exec ai-devbox which terraform-ls
podman exec ai-devbox terraform-ls --version
```

`.vscode/settings.json` points at `/opt/devbox/bin/terraform-ls`. If you
installed to a different prefix, update the setting.

### The integrated terminal has the wrong PATH

The terminal profile must be a **login** shell, otherwise
`/etc/devbox/shell.d/00-env.sh` is not sourced:

```jsonc
"terminal.integrated.profiles.linux": {
  "bash": { "path": "/bin/bash", "args": ["-l"] }
}
```

---

## Git

### `detected dubious ownership in repository`

Git refuses to trust a repository owned by a different uid.

```bash
git config --global --add safe.directory /workspace
```

The entrypoint does this automatically. If you mounted a repo somewhere else,
add that path too.

### SSH keys do not work

They are not mounted by default — deliberately. Options, best first:

1. Use `gh auth login` and HTTPS. No key in the container at all.
2. Forward your agent:
   ```yaml
   volumes:
     - ${SSH_AUTH_SOCK}:/ssh-agent:ro
   environment:
     SSH_AUTH_SOCK: /ssh-agent
   ```
3. Read-only mount `~/.ssh` (uncomment in `compose.yaml`, keep `:ro`).

---

## Terraform

### `init` re-downloads providers every time

```bash
devbox doctor | grep -i plugin
echo "$TF_PLUGIN_CACHE_DIR"
cat ~/.terraformrc
```

The cache must be a mounted volume. If `devbox doctor` reports it as "not a
mount", the volume is missing from `compose.yaml`.

### Provider cache corruption with parallel `init`

```bash
rm -rf ~/.cache/terraform/plugins
terraform init
```

Terraform 1.7+ handles concurrent cache population safely; older versions do
not. If you pin an older Terraform, do not run parallel inits.

### `devbox terraform check` fails on `validate`

`validate` needs provider schemas. `check` runs `init -backend=false` first,
which is offline-safe but still needs to reach the registry.

```bash
terraform providers            # what it is trying to fetch
curl -sS -o /dev/null -w '%{http_code}\n' https://registry.terraform.io/.well-known/terraform.json
```

Behind a proxy, ensure `HTTPS_PROXY` is set in the container environment.

### tflint wants to download plugins

Cloud provider rulesets are commented out in `config/terraform/.tflint.hcl` on
purpose — enabling all three would make the first lint of any repository slow
and noisy. Uncomment the one you use, then:

```bash
tflint --init
```

---

## Kubernetes

### `kubectl` cannot reach the cluster

The kubeconfig is not mounted by default.

```bash
podman exec ai-devbox ls -la ~/.kube
```

Mount it read-only, and prefer a context bound to a `view` ClusterRole rather
than your admin config.

### `localhost` in kubeconfig does not resolve

A kubeconfig pointing at `127.0.0.1` refers to the *host*, not the container.

```bash
sed -i 's|127.0.0.1|host.containers.internal|' ~/.kube/config
```

### GKE: `gke-gcloud-auth-plugin not found`

Build with the GCP module:

```bash
make build-devbox FEATURE_CLOUD_GCP=1
```

---

## AI

### `ai models` shows nothing for a provider

```bash
ai providers          # presence only — values are never printed
devbox doctor         # the "AI platform" section
```

If the credential shows as unset, it was not injected. Check your `.env` or
export it before `podman compose up`.

### `ai ask` fails with "no client available"

The provider has no native CLI and the router is not running:

```bash
podman compose --profile ai-router up -d
curl -sS http://localhost:4000/health/liveliness
```

### `claude` or `codex` behaves oddly after `ai profile`

`ai profile` writes state and re-renders MCP config; it does not modify the
CLIs. Check what changed:

```bash
ai profile
mcp status
cat ~/.mcp.json | jq 'keys'
```

The native CLIs are never wrapped, so any behaviour difference comes from the
MCP servers they now see.

### Local models are unreachable

```bash
ai doctor                                        # reports the ollama URL it tried
curl -sS "$OLLAMA_BASE_URL/api/tags"
```

Host Ollama must listen on all interfaces, not just loopback:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
export OLLAMA_BASE_URL=http://host.containers.internal:11434
```

### A workflow stops early

By design. `ai run` enforces the limits in `ai/policies/policy.yaml`: at most 8
steps, 3 iterations per step, 30 minutes, and every workflow ends at a human.

```bash
grep -A6 '^limits:' ai/policies/policy.yaml
```

If a step was skipped, the provider for that step was not configured — the
output says which.

---

## MCP

### A server is enabled but not exposed

The trust profile is filtering it.

```bash
mcp status              # shows "enabled, but blocked by the X profile"
mcp describe <name>
mcp profile DEVELOPER
```

Remember: `effective = registry ∩ trust profile ∩ security policy`.

### `mcp enable kubernetes` refuses

Working as intended.

```text
error: KUBECONFIG is not set or not readable — refusing to enable
```

Point `KUBECONFIG` at a read-only context bound to a ServiceAccount with the
`view` ClusterRole, then try again.

### `mcp doctor` reports a policy violation

Read the specific message. The two common ones:

- *"read-write with NO scope declared"* — add a `scope:` block. An unscoped
  read-write server is exactly the risk the layer exists to prevent.
- *"requests globally denied env var"* — remove it from `env_passthrough`. No
  MCP server gets a provider or cloud secret unless a trust profile names it.

### Client config is stale

```bash
mcp render
cat ~/.mcp.json | jq
```

The entrypoint renders on every container start; `ai profile` and `mcp
enable/disable` re-render automatically.

---

## Diagnostics to attach to a bug report

```bash
{
  echo "=== versions ==="   ; devbox versions
  echo "=== doctor ==="     ; devbox doctor --json
  echo "=== mcp ==="        ; mcp status
  echo "=== podman ==="     ; podman version && podman info | head -40
  echo "=== image ==="      ; podman image inspect ai-devbox:latest --format '{{json .Config.Labels}}'
} > devbox-diagnostics.txt
```

`devbox doctor` reports credential **presence** only and never prints a value,
so this file is safe to attach. Skim it anyway.
