# Port registry

Human-readable render of [`../inventory/ports.yaml`](../inventory/ports.yaml), the machine-readable
source.
Regenerate this table when the YAML changes.
`scripts/check-ports.py` validates the YAML and cross-checks it against `k8s/` and
`terraform/firewall.tf`.
It does not validate this page.

Before you add a port, read [`runbooks/add-port.md`](runbooks/add-port.md).

`status` values:

- **live**: reachable today.
- **remove**: reachable today, scheduled for removal.
- **target**: planned, not implemented.
- **closed**: not reachable, but the listener exists.
- **removed**: not reachable, and the path is gone.

## Current state

| Port | Proto | Service | Scope | Status | Notes |
|---|---|---|---|---|---|
| 22 | tcp | sshd | public | remove | Key-only root. The firewall allows it from `0.0.0.0/0`. Target is Tailscale-only |
| 80 | tcp | Traefik web | public | live | Cloudflare-proxied. Repository firewall rule uses Cloudflare ranges |
| 443 | tcp | Traefik websecure | public | live | Cloudflare-proxied. Repository firewall rule uses Cloudflare ranges |
| 6443 | tcp | k3s API server | public | remove | Firewall allows it from `0.0.0.0/0`. Target is Tailscale-only |
| 15434 | tcp | vcap v1 Postgres | public | removed | vcap v1 retired 2026-10-27. Traefik entrypoint, route, and firewall rule removed. Port closed |
| 41641 | udp | tailscaled | public | live | Required for NAT traversal |
| 5432 | tcp | vcap v2 legacy Postgres | public | removed | NodePort duplicates deleted 2026-09-29. v2 workloads retired 2026-10-23. No route and no listener |
| 5433 | tcp | vcap v2 legacy Postgres | public | removed | Same as 5432 |
| 15432 | tcp | vcap v2 dev Postgres | public | removed | Workload and Traefik entrypoint removed 2026-10-23. Firewall rule removed and applied 2026-10-23. Port closed |
| 15433 | tcp | vcap v2 staging Postgres | public | removed | Same as 15432 |
| 7881 | tcp | LiveKit room server | public | removed | Removed with the `kirro` workload 2026-10-23. Firewall rule removed and applied 2026-10-23. Port closed |
| 7882 | udp | LiveKit media | public | removed | Removed with the `kirro` workload 2026-10-23. Firewall rule removed and applied 2026-10-23 |
| 30532 | tcp | vcap NodePort duplicate | public | removed | Unmanaged. Deleted 2026-09-29 |
| 30533 | tcp | vcap NodePort duplicate | public | removed | Unmanaged. Deleted 2026-09-29 |
| 32301 | tcp | Traefik NodePort for v2 dev | public | removed | Deleted 2026-09-29 |
| 32131 | tcp | Traefik NodePort for v2 staging | public | removed | Deleted 2026-09-29 |
| 30843 | tcp | Traefik ServiceLB NodePort | public | closed | Bound. No firewall rule |
| 30851 | tcp | Traefik ServiceLB NodePort | public | closed | Bound. No firewall rule |
| 10250 | tcp | kubelet | public | closed | Bound on the public address. No firewall rule |
| 2379 | tcp | etcd client | public | closed | Bound. No firewall rule |
| 2380 | tcp | etcd peer | public | closed | Bound. No firewall rule |
| 9100 | tcp | node-exporter | public | closed | DaemonSet has no `hostNetwork`. No firewall rule |
| 8472 | udp | flannel VXLAN | public | closed | Bound. No firewall rule |

Loopback-only ports are not listed. Examples: `10248`–`10259`, `6444`, `2381`–`2382`, `10010`,
and `53`.

The repository firewall rule for TCP `80` and `443` uses Cloudflare ranges.
Confirm the live firewall before you treat that as enforcement.
The target architecture below is not fully applied.

## Target state

| Port | Proto | Service | Scope | Notes |
|---|---|---|---|---|
| 80 | tcp | Traefik web | public | Cloudflare ranges only |
| 443 | tcp | Traefik websecure | public | Cloudflare ranges only |
| 41641 | udp | tailscaled | public | Unchanged |
| 22 | tcp | sshd | tailnet | No public rule |
| 6443 | tcp | k3s API server | tailnet | No public rule |
| 10250 | tcp | kubelet | tailnet | No public rule |

Everything else stays closed by the Hetzner firewall.
The v2 paths on `15432` and `15433` and the v1 path on `15434` are not part of the target.
Do not reopen them for retained data.

## Historical exposure

On 2026-09-28 the public exposure was TCP `22`, `80`, `443`, `5432`, `5433`, and `6443`.
The `5432` and `5433` paths closed on 2026-09-29.
The v2 workloads, their Traefik entrypoints, and their firewall rules were removed on 2026-10-23.
On 2026-10-27 the v1 entrypoint `vcap-pg-v1` on TCP `15434` and its firewall rule were removed.
This block is history. Do not use it as current state.
