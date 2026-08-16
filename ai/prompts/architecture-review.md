---
agent: architecture-agent
profile: architecture
---
Review the architecture of this repository/system.

Cover:

1. **What this system actually is** — reconstruct it from the code, not from the
   README. Note where the two disagree.
2. **Component boundaries** — are they drawn where the change patterns are? Which
   components always change together, and should therefore be one component?
3. **Coupling and failure domains** — what takes down what. Describe the blast
   radius of each component failing.
4. **Data flow** — where data lives, how it moves, where it crosses a trust
   boundary.
5. **Scalability** — the first bottleneck you would actually hit, and at roughly
   what load. Not a general discussion of scaling.
6. **Operability** — can you tell it is broken before a customer does? Can you
   deploy it on a Friday?
7. **Security posture** — trust boundaries, authn/authz, credential handling,
   least privilege.
8. **Simplification** — what could be removed entirely. This is usually the most
   valuable finding in the review.

Give a recommendation, the options you rejected and why, and the risks that would
change your answer. Say explicitly what you could not determine from the code.
