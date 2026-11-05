# Architecture Decision Records

Why the cluster is built the way it is. Each record states the context, the decision, the alternatives
that were rejected and the consequences that follow — including the unpleasant ones, because a decision
record that only lists benefits is marketing rather than engineering.

These were extracted from the architecture review's target design and implementation brief and from
the migration plan and its ownership model — both kept in the private archive and **not** part of the
published tree. Where those documents carry the full reasoning, an ADR is the durable summary — the
plans are working documents and will be superseded; these should not need to be.

## Format

Every record has: **Status**, **Date**, **Context**, **Decision**, alternatives rejected with the
reason, **Consequences**, and **Evidence** (the files that prove the decision is real rather than
aspirational). Status is one of *Proposed*, *Accepted*, *Superseded*, or *Accepted, partially implemented*.
Use *Proposed* for an unmerged GitOps rollout; name any runtime verification or enforcement gates
explicitly rather than leaving them to be discovered.

Records are append-only in spirit: a changed decision gets a new record that supersedes the old one, so
the reasoning that was once good enough stays visible.

## The records

| # | Decision | Status |
|---|---|---|
| [0001](0001-gitops-argocd.md) | GitOps with ArgoCD (app-of-apps), and three AppProjects as the trust boundary | Accepted |
| [0002](0002-sops-age-ksops.md) | SOPS + age, decrypted by ksops in ArgoCD's repo-server | Accepted |
| [0003](0003-tenant-model.md) | Tenant model: the cluster repo registers tenants, tenant repos own their config | Accepted (contingent on the tenant team's agreement) |
| [0004](0004-origin-ca-tlsstore.md) | One Cloudflare Origin CA certificate via a Traefik `TLSStore` (no cert-manager) | Accepted |
| [0005](0005-static-pv-srv-data.md) | Authoritative data on `/srv/data` via static retained PVs | Accepted, partially implemented |
| [0006](0006-host-restic-backups.md) | Backups run from the host with restic, not inside the cluster | Accepted, partially implemented (no R2 leg; the workstation mirror runs on a daily timer) |
| [0007](0007-keda-scale-to-zero.md) | Scale-to-zero with KEDA and the HTTP add-on | Accepted |
| [0008](0008-traefik-k3s-bundled.md) | Keep k3s's bundled Traefik, configured via one `HelmChartConfig` | Accepted |
| [0009](0009-vcap-postgres-public-ports.md) | The VCAP Postgres instances stay publicly reachable, on moved non-default ports | Accepted, partially implemented |
| [0010](0010-gitorgasm-image-signatures.md) | Verify gitorgasm publication attestations with a namespace-scoped Sigstore controller | Accepted (enforce/Fail configured after verified warn rollout) |

## Adding one

Copy the shape of an existing record. State the decision in the title as an assertion ("Backups run
from the host", not "Backup options"), and be specific in *Consequences* about what got worse — the
accepted trade-offs are the part that a future reader actually needs.
