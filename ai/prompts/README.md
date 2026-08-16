# Prompt library

Reusable prompts. Run one with:

```bash
ai prompt terraform-review           # print it
ai prompt terraform-review --run     # run it against the current directory
ai prompt list
```

Each file is plain markdown with optional front matter naming the agent role and
profile it should run under. Keep them task-shaped and specific — a prompt that
says "review this code" adds nothing over just asking.
