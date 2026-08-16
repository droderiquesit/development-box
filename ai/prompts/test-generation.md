---
agent: code-review-agent
profile: balanced
---
Write tests for the code in scope.

- Start by stating the behaviour under test in one sentence per test. If you
  cannot, the code's contract is unclear and that is the first finding.
- Cover the edges that actually break: empty, one, many; nil/None; boundary
  values; unicode; concurrent access; the error paths.
- Test behaviour through the public interface, not implementation details. A test
  that breaks on every refactor is a liability.
- Each test must be able to fail. If it would pass against a broken
  implementation, it is not testing anything.
- Match the repository's existing test framework, layout and naming exactly.
- No sleeps, no ordering dependencies between tests, no shared mutable state.
- Mock at the boundary (network, clock, filesystem), not internal collaborators.

Report which behaviours you could not test and why.
