---
agent: code-review-agent
profile: deep
---
Propose a refactor of the code in scope.

Before proposing anything, state:

1. What the code currently does — behaviour, not structure.
2. What specifically is wrong with it. "It's messy" is not a reason. Name the
   concrete cost: a bug class it invites, a change it makes expensive, a thing it
   makes untestable.
3. What must not change — the observable behaviour, the public interface, the
   wire format, the performance envelope.

Then propose the smallest refactor that removes the named cost. Sequence it as
steps that each keep the tests green, so it can land incrementally.

If existing tests do not pin the current behaviour well enough to refactor
safely, say so and write those tests first. If the code is fine as it is, say
that — an unnecessary refactor is a pure risk with no upside.
