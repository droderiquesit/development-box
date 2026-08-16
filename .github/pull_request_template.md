## What changed

<!-- One paragraph. What does this do, and why? -->

## Type

- [ ] Tool version bump (`versions.yaml`)
- [ ] New tool or module
- [ ] Governance / policy change
- [ ] MCP registry change
- [ ] Build or CI change
- [ ] Documentation
- [ ] Fix

## Checks

- [ ] `make lint` passes
- [ ] `make validate` passes
- [ ] `make build` succeeds
- [ ] `make test` passes
- [ ] `ai sync --check` passes (if the policy changed)

## If this adds a tool

- [ ] Classified REQUIRED / RECOMMENDED / OPTIONAL in `docs/decisions.md`, with a reason
- [ ] It covers a surface no installed tool already covers
- [ ] Pinned in `versions.yaml` with a Renovate annotation
- [ ] Acquired from a signed repo, `go install`, or a checksum-verified artefact — never `curl | bash`

## If this changes governance

- [ ] `ai/policies/policy.yaml` updated (not the generated files)
- [ ] `ai sync` run and the generated files committed
- [ ] `tests/run.sh guardrails` passes
- [ ] The change does not widen what an AI agent may do without saying so explicitly below

<!-- If it does widen agent permissions, say exactly how, here: -->
