---
agent: terraform-agent
profile: terraform
---
Review the Terraform/OpenTofu in this directory.

Work through these in order and report findings grouped by severity:

1. **Correctness** — does the configuration do what the module documentation and
   variable descriptions claim? Check resource dependencies, `depends_on` that
   should not be there, and implicit ordering that only works by luck.
2. **Provider accuracy** — verify every non-obvious argument and attribute
   against the pinned provider version using the terraform MCP server or
   context7. List anything you could not verify. Do not guess.
3. **Destroy/replace risk** — identify any change that would force replacement of
   a stateful resource (database, disk, bucket, static IP). Put this at the top
   of your report if you find any.
4. **Security** — IAM/RBAC breadth, public exposure, encryption at rest and in
   transit, logging, secrets in variables or defaults.
5. **State and locking** — remote backend configured, locking enabled,
   encryption on, no local state for shared infrastructure.
6. **Structure** — module boundaries, `for_each` vs `count`, repeated blocks that
   want to be a module, unbounded version constraints.
7. **Interface quality** — variable types, descriptions, validation blocks;
   output descriptions; `sensitive = true` where it belongs.
8. **Documentation** — is `terraform-docs` output current?

For each finding: file and line, what is wrong, why it matters, the fix, and how
confident you are. Do not run apply or destroy. If the configuration is sound,
say so.
