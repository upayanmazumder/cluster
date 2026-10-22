# 0009. The VCAP Postgres instances stay publicly reachable, on moved non-default ports

> **Status: SUPERSEDED on 2026-10-23.** The v2 `vcap-dev` and `vcap-staging` workloads were
> retired. Ports `15432` and `15433` are closed, their Traefik entrypoints and routes are removed,
> and their firewall rules are removed. Only the v1 edge on `15434` remains. See
> [`../runbooks/vcap-postgres-access.md`](../runbooks/vcap-postgres-access.md) and
> [`../../changelog/2026-10.md`](../../changelog/2026-10.md). The text below records the earlier
> decision. It is not current guidance.

- **Status:** **Superseded 2026-10-23.** Implemented 2026-09-29. At that time, 5432/5433 were
  closed permanently and ports 15432/15433 were opened with TLS at Traefik, a non-superuser
  application role, a restrictive `pg_hba.conf`, per-person read-only roles, an additive ingress
  NetworkPolicy, and auth-failure alerting. Port 15433 opened only after 15432 had been exercised
  by a real client. The tenant accepted the chart-side change (OD-16). The v2 workloads and their
  ports were later retired. See the notice above.
- **Date:** 2026-09-28 (decided); recorded 2026-09-29.

## Context

The requirement this replaces was absolute: **no public TCP exposure of databases** (SR-4). The
architecture review's S6 stage said the same thing concretely — close 5432/5433 to the world and keep
the databases reachable only from inside.

What that collides with: the tenant's developers are **external**. They are not in the tailnet, they own
their own client tooling, and they connect to the dev and staging databases directly. Every method of
removing the public port therefore asks a third party to change how they work — and the compensating
hardening that would make an exposed port less dangerous (TLS, per-person roles) is *tenant-chart* work
that cannot be written before the tenant agreement exists.

The live state, measured 2026-09-29 rather than inherited from the plan:

- 5432/5433 served connections from an ordinary host until the path was closed on 2026-09-29: the
  unmanaged NodePort duplicate Services were deleted, and the tenant chart's own same-namespace
  `vcap-backend-{dev,staging}-postgres` NetworkPolicy blocks the Traefik route. Nothing answers on
  either port now;
- the path was the Traefik service itself — `type: LoadBalancer` with `5432 → postgres-dev` and
  `5433 → postgres-staging`, routed by unmanaged `IngressRouteTCP` objects in the `vcap-dev` and
  `vcap-staging` namespaces — so the ports were bound cluster-wide rather than by the database pods;
- **nothing fronts them.** The Hetzner firewall still permits 5432/5433 from `0.0.0.0/0`, and the
  traffic never passed through Cloudflare, so Cloudflare's WAF and Access are not in this path at
  all. The target path (15432/15433) is **open** as of 2026-09-29 (N7): the Traefik entrypoints and
  the TLS route were built first, inert from outside because the firewall had no rule, and the rule
  was added last — 15432 before 15433, after each environment's controls were verified.

## Decision

**Keep both instances publicly reachable, move them off the default ports** (dev 15432, staging 15433),
and compensate at the application layer rather than at the network edge:

- TLS on the connection;
- per-person, non-superuser Postgres roles for the tenant's developers, replacing shared use of the
  superuser;
- the superuser confined to the pod network.

SR-4 is relaxed to match: instead of "no public TCP exposure of databases" it requires "no database on a
**default** port, TLS, per-person non-superuser roles, and the superuser confined to the pod network".
The residual risk is the owner's, accepted explicitly, and recorded in the plan rather than softened.

## Alternatives rejected

- **Tailscale node sharing plus ClusterIP via a subnet route** (the plan's own recommendation): rejected
  because it needs every external developer to join the tailnet, which makes the cluster's reachability
  the tenant's problem rather than the cluster's.
- **A namespace-scoped kubeconfig plus `kubectl port-forward` over Tailscale**: same objection, plus
  per-developer kubeconfigs to issue, rotate and explain.
- **Cloudflare Tunnel + Access TCP**: rejected because it inserts a cluster-owner-controlled access layer
  into the tenant's development loop, which muddies the boundary SR-9 draws — the tenant owns and rotates
  its own credentials.
- **Leaving 5432/5433 exactly as they are**: rejected. Moving the port is not a security control on its
  own, but it stops the databases being found by default-port scanning and turns an inherited accident
  into a decision somebody made.

## Consequences

**The risk, stated as a risk:** a public Postgres port serving class-A student data, continuously scanned
and credential-stuffed. Two consequences follow that are easy to miss:

- **The halfway state is the state we are in.** 5432/5433 are closed, so nothing is exposed today —
  but that is a closed path, not a hardened one: the target ports are shut and stay shut until
  VCAP-001 lands and the tenant's chart gains TLS and per-person roles. It would be comfortable to
  call that transitional; it is not, because the hardening depends on an agreement that does not
  exist yet. Opening 15432/15433 is NET-001's work and it is itself blocked on **notifying the
  tenant's developers**, because it changes their connection strings.
- **Cloudflare is not a control for this exposure.** These ports bypass the edge entirely, so NET-003
  restricting origin 80/443 to Cloudflare's ranges — and anything Cloudflare Access protects — changes
  nothing about this record. The two decisions sit next to each other on the same host and do not
  interact.

The public repository must not advertise a property the cluster does not have. `docs/ports.md` keeps
"what is true today" and "what is aimed at" in separate tables for this reason, and
`terraform/firewall.tf` (now in the `cluster` checkout, `cluster/terraform/firewall.tf`) carries the
same split in its own words.

## Evidence

- The decision: the migration plan (private, not published) — the Recorded answers table (D-2), the
  rewritten `NET-001`, and the relaxed `SR-4`.
- The live state: nothing answers on `5432`/`5433` or on `15432`/`15433` on the node's public address
  (TCP connect, 2026-09-29). 5432/5433 stopped serving when the NodePort duplicates were deleted and
  the tenant NetworkPolicy block landed; 15432/15433 listen inside the cluster since N7 but the
  firewall has no rule for them, so nothing outside can complete a connection.
- The mechanism: `kubectl get ingressroutetcp -A` shows the two legacy routes; `kubectl get svc -A`
  no longer lists the deleted NodePort duplicates.
- The firewall: `cluster/terraform/firewall.tf` still allows 5432/5433 from `0.0.0.0/0`, although
  nothing listens — the rule is a leftover, and the 15432/15433 rules do not exist yet.
- The port inventory and its target table: `docs/ports.md`.
- The ownership boundary this decision has to respect: [ADR 0003](0003-tenant-model.md).
