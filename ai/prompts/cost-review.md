---
agent: cost-agent
profile: balanced
---
Analyse the cost of the infrastructure in this repository.

1. Run `infracost breakdown --path .` if a plan is available; otherwise estimate
   and say clearly that you are estimating.
2. Identify the dominant cost drivers — usually two or three line items carry
   most of the bill.
3. Name the pricing dimension for each (per-GB egress, per-request, per
   provisioned hour, per IOP, per ingested GB), so the estimate is checkable.
4. Flag the classic surprises: NAT gateway data processing, cross-AZ traffic,
   log ingestion and retention, snapshot storage, idle load balancers,
   over-provisioned capacity, internet egress.
5. Propose optimisations with the tradeoff stated explicitly — what becomes
   slower, less available, or harder to operate.

Never recommend removing backups, multi-AZ, logging or encryption as a cost
saving without stating exactly what risk is being accepted and who accepts it.
State your confidence; cloud pricing is regional, tiered and changes.
