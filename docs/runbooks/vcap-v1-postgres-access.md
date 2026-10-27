# Runbook: VCAP v1 Postgres external access — retired

**Status: retired 2026-10-27.** Do not use this runbook to connect to a database.

The vcap v1 platform was retired on 2026-10-27. The public Postgres edge on TCP 15434 was open from
2026-10-03 to 2026-10-27. It no longer exists.

| Item | State |
|---|---|
| Applications `vcap-backend-v1` and `vcap-frontend-v1`, AppProject `vcap` | removed |
| Deployments, Services, Ingresses, and CronJobs in `vcap-v1` | removed |
| `IngressRouteTCP` `vcap-v1-postgres` and `TLSOption` `vcap-pg` | removed |
| Traefik entrypoint `vcap-pg-v1` (TCP 15434) | removed |
| Terraform firewall rule for TCP 15434 | removed and applied. The port is closed. |
| Hostnames `vcap.upayan.dev` and `api-vcap.upayan.dev` | return 404 |
| `pg-v1.upayan.dev:15434` | closed |

No listener exists on 15434. No client setting can reach the database. The firewall now allows only
TCP 22, 80, 443 (Cloudflare ranges), and 6443, UDP 41641, and ICMP.

## Retained data

The namespace `vcap-v1` still holds data. No workload uses it.

- PVC `vcap-backend-v1-postgres-data` (static PV `vcap-v1-postgres-data-vps`, Retain). The host
  path is `/srv/data/vcap-v1-postgres`.
- PVC `vcap-backend-v1-data` (local-path PV, reclaim policy Retain).
- Final dump: `/srv/data/vcap-v1-final-dump/vcap-v1-pg_dumpall-20261027.sql.gz`.
- Secrets `auth-env`, `backend-env`, `pull-secret`, and `vcap-v1-postgres-edge-tls`.

Never start Postgres on the retained data directory. Restore the final dump or start a temporary pod
on a copy. See Variant A in [`restore-postgres.md`](restore-postgres.md).

The earlier v2 retirement is in [`vcap-postgres-access.md`](vcap-postgres-access.md).
