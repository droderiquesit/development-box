# AI rules

This directory is intentionally almost empty.

Rules are **not** maintained here. They live in `ai/policies/policy.yaml`, which
is the single canonical source, and are rendered into each AI client's native
instruction file by:

```bash
ai sync            # regenerate
ai sync --check    # fail if any generated file is stale (runs in CI + pre-commit)
```

Generated outputs:

| File | Consumed by |
|---|---|
| `CLAUDE.md` | Claude Code |
| `AGENTS.md` | Codex CLI, and every other client that reads AGENTS.md |
| `GEMINI.md` | Gemini CLI |
| `.github/copilot-instructions.md` | GitHub Copilot / VS Code AI extensions |
| `.cursor/rules/devbox-policy.mdc` | Cursor |

Maintaining the same security policy by hand in five files is how three of them
end up wrong. If you need to change a rule, change `policy.yaml` and run
`ai sync`.

## Repository-local additions

A project can add rules that apply only to itself by creating `.ai/rules/*.md`
in that repository. Those are additive: they are appended after the generated
policy and can tighten it, never loosen it.
