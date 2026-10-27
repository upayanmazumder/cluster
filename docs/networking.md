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
| udp/41641 | `0.0.0.0/0`, `::/0` | Tailscale NAT traversal |
| icmp | `0.0.0.0/0`, `::/0` | Answered |

TCP `15432`, TCP `15433`, TCP `15434`, TCP `7881`, and UDP `7882` are absent from the repository.
Their last consumers were the vcap v2, vcap v1, and kirro workloads.
Terraform applied the v2 and kirro removals to firewall `11692068` on 2026-10-23.
Terraform applied the `15434` removal on 2026-10-27.
Public probes confirm that ports `15432`, `15433`, and `15434` are closed.
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

## vcap Postgres exposure (retired)

> **Retired 2026-10-27.** vcap v1 is retired. No database port is open.

Traefik no longer has entrypoint `vcap-pg-v1`. `IngressRouteTCP/vcap-v1-postgres` and TLSOption
`vcap-pg` are removed. `pg-v1.upayan.dev:15434` is closed. The firewall allows no database port.

The v2 entrypoints and routes are gone too.
The retained `vcap-dev`, `vcap-staging`, and `vcap-v1` data serves no traffic.
Do not add a listener or firewall rule for retained data.
To recover the retained v1 data, see [`runbooks/restore-postgres.md`](runbooks/restore-postgres.md).

## NetworkPolicy posture

Every app namespace denies ingress by default. The patterns:

| Shape | Namespaces | Allowed ingress |
|---|---|---|
| KEDA HTTP fronted | `cas-api`, `dj-html-nodejs-web`, `learning-docker`, `learning-qwik`, `smart-home-system-api` | Interceptor pod in namespace `keda` only |
| Direct Traefik | `cheatsheet`, `kodesphere`, `learning-react`, `meghmitra`, `prism-streaming-rag`, `status-page`, `upayan-api` | Traefik in `kube-system`; `upayan-api` admits Traefik only |
| No ingress | `mochi` | Nothing. Outbound Discord bot |

Datastore pods allow same-namespace traffic only.

Two rules:

- Intra-namespace rules use an empty `podSelector`. The namespace is the trust boundary.
- Policies for charts that ship none live in this repository, next to the app manifests.

The retained namespaces, including `vcap-v1`, run no pods. Their NetworkPolicies do nothing.

## Target architecture

Three layers, one owner each:

```text
Cloudflare (proxy, Full strict, Always HTTPS)
   │ 80/443 only, from Cloudflare ranges
Hetzner Cloud Firewall "vps" (Terraform-managed)
   │ allow: 80,443 (Cloudflare) · 41641/udp (Tailscale) · icmp
   │ drop: everything else, including tcp 22 and 6443
Host (Ansible-managed)
   │ Tailscale is the only path to SSH (22), k3s API (6443), kubelet (10250)
```

Decisions:

- **No database port is public.** vcap v1 was retired on 2026-10-27 and TCP `15434` is closed.
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
