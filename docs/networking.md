# Networking

Port-by-port detail lives in [`ports.md`](ports.md) and
[`../inventory/ports.yaml`](../inventory/ports.yaml).
This page covers the layers.

## Current state

A Hetzner Cloud Firewall named `vps` is attached.
Terraform manages it as an allow-list.
The repository declares these rules:

| Rule | Source | Note |
|---|---|---|
| tcp/22 | `0.0.0.0/0`, `::/0` | Root SSH, key-only. Target is Tailscale-only |
| tcp/80, tcp/443 | Cloudflare published ranges | Built from `data.cloudflare_ip_ranges` |
| tcp/6443 | `0.0.0.0/0`, `::/0` | k3s API server. Target is Tailscale-only |
| tcp/15434 | `0.0.0.0/0`, `::/0` | vcap v1 Postgres edge, TLS required |
| udp/41641 | `0.0.0.0/0`, `::/0` | Tailscale NAT traversal |
| icmp | `0.0.0.0/0`, `::/0` | Answered |

TCP `15432`, TCP `15433`, TCP `7881`, and UDP `7882` are absent from the repository.
Their last consumers, the vcap v2 and kirro workloads, were removed on 2026-10-23.
Terraform applied the same removals to firewall `11692068` on 2026-10-23.
Public probes confirm that ports `15432` and `15433` are closed.
`7881` is closed too.

All other ports are dropped. Host `iptables` INPUT policy is `ACCEPT`. `ufw` is inactive.
No `fail2ban` runs. The cloud firewall is the only packet filter.

Closed by the absence of rules:

- kubelet `10250`
- etcd client and peer `2379` and `2380`
- flannel VXLAN `8472`
- node-exporter `9100`
- Traefik NodePorts

Some of these ports are still bound on the host. The firewall makes them unreachable.

## vcap Postgres exposure

Only the `vcap-v1` Postgres is public.
Traefik listens on TCP `15434` through entrypoint `vcap-pg-v1`.
The `IngressRouteTCP/vcap-v1-postgres` route matches SNI `pg-v1.upayan.dev` and forwards to
`vcap-backend-v1-postgres:5432`.
TLS is mandatory. The route uses Secret `vcap-v1-postgres-edge-tls` and TLSOption `vcap-pg`.
The path is reachable from any address. The database password is the only client guard.
Authentication failures are alerted.
See [`certificates.md`](certificates.md) and
[`runbooks/vcap-v1-postgres-access.md`](runbooks/vcap-v1-postgres-access.md).

The v2 entrypoints and routes are gone.
The retained `vcap-dev` and `vcap-staging` data serves no traffic.
Do not add a listener or firewall rule for retained data.

## NetworkPolicy posture

Every app namespace denies ingress by default. The patterns:

| Shape | Namespaces | Allowed ingress |
|---|---|---|
| KEDA HTTP fronted | `cas-api`, `dj-html-nodejs-web`, `learning-docker`, `learning-qwik`, `smart-home-system-api` | Interceptor pod in namespace `keda` only |
| Direct Traefik | `cheatsheet`, `kodesphere`, `learning-react`, `meghmitra`, `prism-streaming-rag`, `status-page`, `upayan-api`, `vcap-v1` frontend | Traefik in `kube-system`; `upayan-api` admits Traefik only |
| No ingress | `mochi` | Nothing. Outbound Discord bot |

Datastore pods allow same-namespace traffic only.
The `vcap-v1` Postgres is the exception. It admits Traefik through its `IngressRouteTCP`.

Two rules:

- Intra-namespace rules use an empty `podSelector`. The namespace is the trust boundary.
- Policies for charts that ship none live in this repository, next to the app manifests.

The retained namespaces run no pods. Their NetworkPolicies do nothing.

## Target architecture

Three layers, one owner each:

```text
Cloudflare (proxy, Full strict, Always HTTPS)
   │ 80/443 only, from Cloudflare ranges
Hetzner Cloud Firewall "vps" (Terraform-managed)
   │ allow: 80,443 (Cloudflare) · 15434 (world, TLS) ·
   │        41641/udp (Tailscale) · icmp
   │ drop: everything else, including tcp 22 and 6443
Host (Ansible-managed)
   │ Tailscale is the only path to SSH (22), k3s API (6443), kubelet (10250)
```

Decisions:

- **The vcap v1 Postgres stays public on TCP `15434`.** The owner accepted this exposure.
  TLS, per-person non-superuser roles, a `pg_hba` that refuses network superuser logins, and
  auth-failure alerting remain the hardening requirements.
- **Admin plane is Tailscale-only.** No public SSH and no public API. Last-resort access is the
  Hetzner console or rescue system. See [`runbooks/recover-vm.md`](runbooks/recover-vm.md).
- **The Hetzner firewall is the only packet filter managed by this repository.** Do not add
  `ufw` or `nftables` rules from Ansible. They conflict with kube-proxy and kube-router.
- **No listener without a consumer.** Do not add a Traefik entrypoint, firewall rule, or
  `IngressRouteTCP` for retained data.

## Related

- [`ports.md`](ports.md) and [`../inventory/ports.yaml`](../inventory/ports.yaml)
- [`certificates.md`](certificates.md)
- [`secrets.md`](secrets.md)
- [`runbooks/add-port.md`](runbooks/add-port.md)
