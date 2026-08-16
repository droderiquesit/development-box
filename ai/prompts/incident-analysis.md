---
agent: sre-agent
profile: code-review
---
Perform a blameless incident analysis from the material provided (logs, metrics,
timeline, code, alerts).

1. **Timeline** — chronological, with times. Label each entry as OBSERVED or
   INFERRED. Do not blur the two.
2. **Impact** — who, how many, how long, in user-visible terms.
3. **Detection** — how was it found, how long did that take, and did alerting
   find it before a human did?
4. **Contributing factors** — plural. Include the conditions that let a single
   fault become an outage: missing guardrail, absent test, unclear runbook,
   ambiguous ownership.
5. **What went well** — genuinely, so the practice survives.
6. **Action items** — specific, prioritised, each with a clear owner-shaped
   description and a definition of done.

Blameless means describing what the system permitted, not who typed it. If the
evidence does not support a conclusion, say the evidence is insufficient.
