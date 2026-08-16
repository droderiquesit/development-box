---
agent: documentation-agent
profile: balanced
---
Write or update documentation for this code.

- Lead with what it is and why it exists. The "why" cannot be recovered from the
  code, so it is the most valuable thing you can write.
- Write for a competent engineer who has not seen this before.
- Every command must be copy-pasteable and correct. Verify what you can; say what
  you could not verify.
- Include the failure modes and troubleshooting, not just the happy path.
- Use obvious placeholders for anything credential-, host- or account-shaped.
- Keep generated content generated (`terraform-docs`), not hand-maintained.
- Update docs in the same change as the code.

Prefer a short accurate page to a long comprehensive one.
