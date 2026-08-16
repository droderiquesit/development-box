# Agent roles

These are **reusable instruction/context profiles**, not services. There is no
daemon, no queue and no orchestration engine — an agent role is a markdown file
that gets prepended to a conversation, plus a profile that decides which model
and which permissions apply.

That is a deliberate architectural choice. A role that is a file can be diffed,
reviewed, versioned and used by any AI client. A role that is a microservice is
an operational burden that buys nothing.

Use one with:

```bash
ai agent terraform-agent          # start a session in this role
ai run terraform-review           # run the workflow that chains several roles
```

Each role declares its own front matter: which profile it runs under, which MCP
servers it may use, and which rule sets from `ai/policies/policy.yaml` apply.
`devbox ai sync` renders that into each client's native config.
