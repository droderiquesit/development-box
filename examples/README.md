# Examples

Working examples you can run inside the DevBox to verify the whole toolchain
end to end. They are deliberately small — enough to exercise every check, not
enough to be a project.

| | |
|---|---|
| `terraform/` | A module that passes `devbox terraform check` cleanly. Use it to confirm fmt, validate, tflint, checkov, conftest and terraform-docs all work. |
| `github-actions/` | A workflow that passes `devbox github check`, showing the security patterns the `github-agent` enforces. |

```bash
cd examples/terraform && devbox terraform check
cd examples             && devbox github check
```
