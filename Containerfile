# syntax-agnostic OCI Containerfile — builds with `podman build`, `buildah bud`
# or `docker build`, with or without BuildKit. No RUN --mount, no heredocs.
# =============================================================================
# AI ENGINEERING DEVBOX
# =============================================================================
# Built FROM ai-devbox-base, which carries the OS, the non-root user and the
# language runtimes. This image adds everything that moves quickly:
#   IaC · Kubernetes/GitOps · GitHub · security & supply chain · cloud CLIs
#   AI clients · MCP servers · governance config · the devbox/ai/mcp CLIs
#
#   make build          # pulls the pinned published base, then builds this
#   podman build -f Containerfile -t ai-devbox:latest .
#
# MODULARITY
#   Every optional module is a build ARG. Nothing below is load-bearing for
#   anything above it, so turning a module off never breaks another.
#     FEATURE_CLOUD_AWS / _AZURE / _GCP   cloud CLIs        (default off)
#     FEATURE_K8S_LOCAL                   kind              (default off)
#     FEATURE_AI_GEMINI                   Gemini CLI        (default on)
#     FEATURE_AI_EXTRA                    aider + opencode  (default off)
#     FEATURE_MCP_BROWSER / _KUBERNETES   extra MCP servers (default off)
#     FEATURE_ANSIBLE                     ansible-lint      (default off)
#     FEATURE_EXTRA_TUI                   lazygit           (default on)
#   Runtime toggles (MCP servers, AI providers, profiles) need no rebuild at
#   all — they live in ~/.config/devbox and are edited with `mcp` / `ai`.
# =============================================================================

# The DevBox builds FROM a PUBLISHED release of the Base Image Factory's
# ai-engineering image (repo: droderiquesit/ai-devbox), pulled from the
# registry — the base's whole lifecycle (build, harden, test, scan, sign,
# version) lives in that repository, not this one. Keep this default in step
# with the `base:` section of versions.yaml; CI passes the resolved ref
# (digest-pinned when versions.yaml pins one) explicitly.
ARG BASE_IMAGE_REF=ghcr.io/droderiquesit/ai-devbox/ai-engineering:1.0.0

# -----------------------------------------------------------------------------
# STAGE 1 — builder. Compiles every Go tool. Discarded afterwards, so the ~1.2 GB
# Go module + build cache never lands in the shipped image.
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE_REF} AS gotools

USER root
ARG FEATURE_K8S_LOCAL=0
ARG FEATURE_EXTRA_TUI=1
ENV GOPATH=/tmp/gopath \
    GOBIN=/opt/go-bin \
    GOMODCACHE=/tmp/gopath/pkg/mod \
    GOCACHE=/tmp/gocache \
    FEATURE_K8S_LOCAL=${FEATURE_K8S_LOCAL} \
    FEATURE_EXTRA_TUI=${FEATURE_EXTRA_TUI}

COPY scripts/lib/ /opt/devbox/scripts/lib/
COPY versions.yaml /opt/devbox/versions.yaml
COPY scripts/install/25-go-tools.sh scripts/install/26-release-tools.sh /opt/devbox/scripts/install/
RUN chmod +x /opt/devbox/scripts/install/2*.sh && \
    DEVBOX_VERSIONS_FILE=/opt/devbox/versions.yaml \
    /opt/devbox/scripts/install/25-go-tools.sh
# Tools whose go.mod carries `replace` directives cannot be `go install`ed; they
# come from checksum-verified release artefacts instead.
RUN DEVBOX_VERSIONS_FILE=/opt/devbox/versions.yaml \
    /opt/devbox/scripts/install/26-release-tools.sh

# -----------------------------------------------------------------------------
# STAGE 2 — the DevBox itself.
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE_REF} AS devbox

USER root
SHELL ["/bin/bash", "-lc"]

ARG BASE_IMAGE_REF
# The manifest digest the base ref resolved to at build time — CI passes it
# from the resolve step so the shipped image names its exact foundation, not
# just the tag that was asked for. "unknown" only in ad-hoc local builds.
ARG BASE_IMAGE_DIGEST=unknown
ARG DEV_USER=dev
ARG DEV_UID=1000
ARG DEV_GID=1000
ARG FEATURE_CLOUD_AWS=0
ARG FEATURE_CLOUD_AZURE=0
ARG FEATURE_CLOUD_GCP=0
ARG FEATURE_K8S_LOCAL=0
ARG FEATURE_AI_GEMINI=1
ARG FEATURE_AI_EXTRA=0
ARG FEATURE_MCP_BROWSER=0
ARG FEATURE_MCP_KUBERNETES=0
ARG FEATURE_ANSIBLE=0
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG VERSION=dev

LABEL org.opencontainers.image.title="ai-devbox" \
      org.opencontainers.image.description="Enterprise AI Engineering DevBox: IaC, Kubernetes, cloud, security and a governed multi-provider AI/MCP platform" \
      org.opencontainers.image.source="https://github.com/droderiquesit/development-box" \
      org.opencontainers.image.documentation="https://github.com/droderiquesit/development-box/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.base.name="${BASE_IMAGE_REF}" \
      org.opencontainers.image.base.digest="${BASE_IMAGE_DIGEST}"

ENV FEATURE_CLOUD_AWS=${FEATURE_CLOUD_AWS} \
    FEATURE_CLOUD_AZURE=${FEATURE_CLOUD_AZURE} \
    FEATURE_CLOUD_GCP=${FEATURE_CLOUD_GCP} \
    FEATURE_K8S_LOCAL=${FEATURE_K8S_LOCAL} \
    FEATURE_AI_GEMINI=${FEATURE_AI_GEMINI} \
    FEATURE_AI_EXTRA=${FEATURE_AI_EXTRA} \
    FEATURE_MCP_BROWSER=${FEATURE_MCP_BROWSER} \
    FEATURE_MCP_KUBERNETES=${FEATURE_MCP_KUBERNETES} \
    FEATURE_ANSIBLE=${FEATURE_ANSIBLE} \
    DEVBOX_VERSIONS_FILE=/opt/devbox/versions.yaml

COPY scripts/lib/  /opt/devbox/scripts/lib/
COPY versions.yaml /opt/devbox/versions.yaml
COPY scripts/install/ /opt/devbox/scripts/install/
RUN chmod +x /opt/devbox/scripts/install/*.sh /opt/devbox/scripts/lib/*.sh

# --- Go binaries from the builder stage -------------------------------------
# Placed in /opt/devbox/bin, which 00-env.sh puts on PATH for every user.
COPY --from=gotools /opt/go-bin/ /opt/devbox/bin/
RUN chmod 0755 /opt/devbox/bin/* && ls -1 /opt/devbox/bin | wc -l

# --- vendor-packaged tooling (each its own layer, ordered by change rate) ----
RUN /opt/devbox/scripts/install/30-iac.sh
RUN /opt/devbox/scripts/install/35-devtools.sh
RUN /opt/devbox/scripts/install/40-kubernetes.sh
RUN /opt/devbox/scripts/install/50-security.sh
COPY security/allowlists/ /opt/devbox/security/allowlists/
RUN /opt/devbox/scripts/install/60-cloud.sh

# --- language-ecosystem CLIs (run as the dev user: uv/npm write to shared,
#     group-writable tool roots and must not create root-owned files) ---------
USER ${DEV_USER}
RUN /opt/devbox/scripts/install/55-python-tools.sh
RUN /opt/devbox/scripts/install/70-ai.sh
RUN /opt/devbox/scripts/install/75-mcp.sh

# --- governance, configuration and the developer CLIs -----------------------
USER root
COPY bin/     /opt/devbox/bin/
COPY ai/      /opt/devbox/ai/
COPY mcp/     /opt/devbox/mcp/
COPY security/ /opt/devbox/security/
COPY config/  /opt/devbox/config/
COPY scripts/configure/ /opt/devbox/scripts/configure/
COPY scripts/health/    /opt/devbox/scripts/health/
COPY scripts/security/  /opt/devbox/scripts/security/
# The DevBox's shell drop-ins, via the base image's documented extension
# contract: files in /etc/devbox/shell.d/ are sourced after the base's own
# 00-env.sh, in name order. 05 = DevBox env (Terraform/K8s/AI vars, the
# devbox CLIs on PATH), 10 = aliases, 20 = prompt. The 05 env file is also
# symlinked into /etc/profile.d/ — same as the base does with its 00 — so
# non-interactive login shells (`bash -lc`, CI run-steps) see it too.
COPY config/shell/05-devbox-env.sh /etc/devbox/shell.d/05-devbox-env.sh
COPY config/shell/10-aliases.sh    /etc/devbox/shell.d/10-aliases.sh
COPY config/shell/20-prompt.sh     /etc/devbox/shell.d/20-prompt.sh
RUN ln -sf /etc/devbox/shell.d/05-devbox-env.sh /etc/profile.d/05-devbox-env.sh && \
    chmod +x /opt/devbox/bin/devbox /opt/devbox/bin/ai /opt/devbox/bin/mcp \
             /opt/devbox/scripts/configure/*.sh \
             /opt/devbox/scripts/health/*.sh \
             /opt/devbox/scripts/security/*.sh && \
    ln -sf /opt/devbox/bin/devbox /usr/local/bin/devbox && \
    ln -sf /opt/devbox/bin/ai     /usr/local/bin/ai && \
    ln -sf /opt/devbox/bin/mcp    /usr/local/bin/mcp && \
    /opt/devbox/scripts/configure/image-finalize.sh

# --- entrypoint --------------------------------------------------------------
COPY scripts/configure/entrypoint.sh /usr/local/bin/devbox-entrypoint
RUN chmod +x /usr/local/bin/devbox-entrypoint

USER ${DEV_USER}
WORKDIR /workspace
ENV HOME=/home/${DEV_USER}

# PATH is an IMAGE property, not a login-shell property. HEALTHCHECK,
# `docker exec <cmd>`, VS Code server processes and CI run-steps all execute
# without a login shell; when the tool roots only enter PATH through
# /etc/devbox/shell.d/00-env.sh, every one of those contexts sees a crippled
# image — the healthcheck reported `yq`/`claude`/`codex` missing while an
# interactive shell in the same container found all three. Order mirrors the
# profile: user overrides > devbox CLIs > npm/uv tool roots > Go > system.
# The profile's idempotent prepends then agree with this instead of fighting it.
ENV PATH=/home/${DEV_USER}/.local/bin:/opt/devbox/bin:/opt/devbox/npm-global/bin:/opt/devbox/uv-tools/bin:/home/${DEV_USER}/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# `devbox doctor --quiet` is the health check: it exercises the real tool
# surface rather than asserting that a single binary happens to exist.
HEALTHCHECK --interval=2m --timeout=30s --start-period=20s --retries=2 \
  CMD /opt/devbox/bin/devbox doctor --quiet --core-only || exit 1

ENTRYPOINT ["/usr/local/bin/devbox-entrypoint"]
CMD ["sleep", "infinity"]
