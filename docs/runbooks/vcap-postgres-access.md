# Runbook: VCAP v2 Postgres external access — retired

**Status: retired 2026-10-23.** Do not use this runbook to connect to a database.

The v2 development and staging workloads no longer run. Their network routes and public ports are
also gone:

| Item | State |
|---|---|
| `vcap-dev` and `vcap-staging` Deployments, Services, and Pods | deleted |
| `vcap-postgres-dev` and `vcap-postgres-staging` `IngressRouteTCP` | deleted |
| Traefik entrypoints on TCP `15432` and `15433` | removed from `k8s/platform/traefik/traefik-config.yaml` |
| Firewall rules for TCP `15432` and `15433` | removed from `terraform/firewall.tf` |
| Data in both namespaces | retained on `Retain` PVs |

No listener exists on `15432` or `15433`. No certificate or `pg_hba.conf` change can make these
databases reachable. Reopening them requires a new deliberate decision, a restored workload, a
Traefik route, and a firewall rule.

ADR [`0009`](../adr/0009-vcap-postgres-public-ports.md) records the earlier v2 decision. It is
superseded.

## Current v1 access

The live database is `vcap-v1/vcap-backend-v1-postgres`. Use
[`vcap-v1-postgres-access.md`](vcap-v1-postgres-access.md). The only Postgres edge is TCP `15434`
with SNI `pg-v1.upayan.dev`.

## Retained v2 data

The data is static. To read it, restore a copy. Do not start Postgres on the retained tree.

1. Restore the class-A `vcap-staging` tree or the class-C `vcap-dev` tree from restic.
2. Copy the `pgdata` tree to a scratch path.
3. Start a temporary `postgres:16` pod with `PGDATA` on the copy.
4. Do not create a Service, `IngressRouteTCP`, or firewall rule.

See [`restore-postgres.md`](restore-postgres.md).
