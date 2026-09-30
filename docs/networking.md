# Networking

Full detail: the architecture review (private, not published) §4 (port audit), §5 (security findings), §7 (target architecture). Port-by-port detail lives in
[`ports.md`](ports.md) and [`../inventory/ports.yaml`](../inventory/ports.yaml) — this page covers
the layers, not the individual ports.

## Current state

- **A Hetzner Cloud Firewall exists and is deliberately permissive.** The `vps` firewall (Terraform
  `hcloud_firewall`, held in the `cluster` checkout at `cluster/terraform/firewall.tf`) allows 22, 80,
  443, 6443, 5432, 5433, udp/41641 and icmp from anywhere, and drops nothing else it is not asked to.
  Attaching it changed nothing about reachability. Host `iptables` INPUT policy is `ACCEPT`, `ufw`
  inactive, no `fail2ban`.
- Everything k3s/kube-proxy expose is reachable from the internet by default: HTTP/HTTPS (fine,
  Cloudflare-proxied), but also the k3s apiserver, kubelet, embedded etcd (client + peer ports —
  a leftover from the deleted 2-node era), and node-exporter (leaking ~2.9k host metrics with no
  auth).
- **vcap Postgres is no longer reachable from the internet.** 5432/5433 were Traefik TCP passthrough
  entrypoints plus **unmanaged** `IngressRouteTCP` objects and duplicate NodePort Services; the
  NodePorts were deleted 2026-09-29 and the tenant chart's own same-namespace NetworkPolicy blocks the
  Traefik path, so nothing answers. The target public path is **15432/15433** and it is **not open
  yet** — the hardening it depends on (TLS, per-person non-superuser roles, a network-superuser-locking
  `pg_hba`, alerting) does not exist.
- Admin access (SSH, `kubectl`) is currently possible from the public IP as well as Tailscale.
- Full port-by-port state: [`ports.md`](ports.md) "Current state" table.

## NetworkPolicy posture (S11 — implemented 2026-09-28)

Before S11 the cluster had no pod-level policy at all: only the `argocd` namespace had any
(`argocd-*-network-policy`, shipped by the upstream chart) and `vcap-backend-*-auth` had a single
one. k3s's bundled kube-router netpol controller does enforce `NetworkPolicy`, so these are real
rules, not decoration.

Every app namespace now denies ingress by default. Two shapes, chosen per the app's real traffic
path (traced live before writing anything):

| Shape | Namespaces | Allowed ingress |
|---|---|---|
| KEDA-HTTP-fronted | `cas-api`, `dj-html-nodejs-web`, `learning-docker`, `learning-qwik`, `smart-home-system-api`, `upayan-v5` | the interceptor pod in namespace `keda` (`app.kubernetes.io/component=interceptor`) only — public traffic reaches these via `k8s/platform/keda-add-ons-http-routes/`, never directly from Traefik |
| Direct Traefik | `bandit`, `bitvault`, `cheatsheet`, `kodesphere`, `learning-react`, `meghmitra`, `prism-streaming-rag`, `rankstack`, `status-page`, `upayan-web`, vcap frontend `web` | Traefik (`kube-system`, `app.kubernetes.io/name=traefik`) + same-namespace pods, per workload on its real port |
| No ingress at all | `mochi` | nothing — Discord gateway bot, outbound only, no Ingress exists |

Datastore pods (meghmitra `postgres`; bitvault `postgres`/`minio`; rankstack `mongo`/`redis`;
rankstack/bitvault `redis`) additionally allow **same-namespace only** — none of them are
NodePort/LoadBalancer or routed by Traefik, so nothing legitimate arrives from outside.

Two rules of thumb this design follows deliberately:

- Intra-namespace "from" rules use an **empty `podSelector`** (all pods in that namespace), not
  label matching. The namespace is the trust boundary, and inside it label matching already caused
  one silent break (the vcap API policy blocking its own frontend, 2026-09-28) plus one near-miss
  (`app.kubernetes.io/part-of: vcap` is not applied to every pod template in that chart).
- Policies for charts that ship none (`rankstack`, the vcap frontend) live **in this repo**
  (`k8s/apps/rankstack/manifests/`, `k8s/apps/vcap/frontend-manifests/`) and are applied by a
  third `sources` entry on those explicit Applications — so all cluster network policy stays in the
  cluster's own source of truth.

**vcap Postgres is now covered by the tenant chart's own policy.** `vcap-backend-{dev,staging}-postgres`
(chart-owned, 2026-09-28) admits the same namespace only, and that is what closed the direct Traefik
path to 5432/5433 once the unmanaged NodePort duplicates were deleted on 2026-09-29. There is still no
namespace-wide default-deny in `vcap-dev`/`vcap-staging`: the chart's `worker` and Job pods carry their
own rules, and a blanket deny written from this repo would cut traffic the chart owns. When 15432/15433
is built, the public edge is a separate **additive**, cluster-owned ingress policy — never a revert of
the tenant's same-namespace rule (see [`ports.md`](ports.md)).

## Target architecture (S2/S6, not yet implemented)

Three layers, each with exactly one owner (see [`architecture.md`](architecture.md)):

```
Cloudflare (proxy, Full(strict), Always HTTPS)
   │ 80/443 only, from Cloudflare's published IP ranges
Hetzner Cloud Firewall "vps" (Terraform-managed)
   │ allows: 80,443 (from Cloudflare ranges) · 15432,15433 (from anywhere, TLS-hardened — not yet) ·
   │ 41641/udp (Tailscale, from anywhere) · icmp
   │ everything else: no rule → dropped, including tcp 22 and 6443
Host (Ansible-managed)
   │ Tailscale is the only path to SSH (22) and the k3s API (6443)/kubelet (10250)
```

Key decisions (owner-confirmed, OD-1):

- **vcap Postgres stays public on moved non-default ports — 15432 (dev), 15433 (staging)** — any IP
  may connect, but only once the connection is hardened with TLS (private CA), per-person
  non-superuser roles, a `pg_hba` that refuses network superuser logins, and auth-failure alerting.
  **5432/5433 are closed permanently and are not the target; 15432/15433 are open and verified** (both
  the firewall rule nor the Traefik entrypoint exists). See [`certificates.md`](certificates.md) for
  the TLS side.
- **Admin plane (SSH, k8s API, kubelet) is Tailscale-only** — no public SSH, no IP allowlist.
  Last-resort access is the Hetzner web console / rescue system, documented in
  [`runbooks/recover-vm.md`](runbooks/recover-vm.md).
- The Hetzner firewall is the **only** packet filter managed by this repo's tooling — no `ufw`/
  `nftables` rules from Ansible (they'd fight kube-proxy/kube-router); k3s-owned iptables chains
  stay k3s-owned.
- node-exporter loses its public exposure (bind `127.0.0.1` or drop `hostNetwork`) and the
  duplicate NodePort/etcd/kubelet/apiserver ports are closed by the firewall.

## Related

- [`ports.md`](ports.md) / [`../inventory/ports.yaml`](../inventory/ports.yaml) — the authoritative port-by-port registry
- [`certificates.md`](certificates.md) — TLS design for both the web hosts and vcap Postgres
- [`secrets.md`](secrets.md) — how the Postgres per-person credentials and TLS keys are stored
- [`runbooks/add-port.md`](runbooks/add-port.md) — how to add a new port without creating a collision
