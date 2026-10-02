# Port registry

Human-readable render of [`../inventory/ports.yaml`](../inventory/ports.yaml), the machine-readable
source of truth. Regenerate this table by hand whenever the YAML changes (no generator script yet
— keep them in sync manually, `scripts/check-ports.py` validates the YAML's internal consistency
and cross-checks it against `k8s/` manifests **and `terraform/firewall.tf`**, not this file's prose).

Before adding a new port: read [`runbooks/add-port.md`](runbooks/add-port.md).

`status`: **live** = reachable today · **open** = reachable today, deliberately and recently
opened · **remove** = reachable today, scheduled for removal · **target** = planned, not yet
implemented · **closed** = not reachable; the listener exists but nothing can get to it ·
**removed** = not reachable; the path itself is gone. (The definitions of `closed` and `open` above
were the wrong way round until 2026-09-30 — `open` read "target state, deliberately not yet
listening" while the two ports carrying it were live and serving. `scripts/check-ports.py` now
validates the set and compares the first three against the firewall.) §4 of the architecture review (kept private, not
published) holds the full current-state audit this table is derived from (verified 2026-09-27 via `ss
-Hltnp`/`ss -Hlunp` on the node + an external TCP probe).

## Current state (today)

| Port | Proto | Service | Scope | Status | Notes |
|---|---|---|---|---|---|
| 22 | tcp | sshd | public | remove | key-only root, **and the firewall does allow it from `0.0.0.0/0`** — still genuinely reachable. Closing it is N5, gated on a proven tailnet path from every admin machine |
| 80 | tcp | traefik (web) | public | live | Cloudflare-proxied, all `*.upayan.dev` hosts |
| 443 | tcp | traefik (websecure) | public | live | Cloudflare-proxied, all `*.upayan.dev` hosts |
| 5432 | tcp | vcap-dev postgres (legacy path) | public | closed | **closed, never reopens** — the unmanaged NodePort duplicate was deleted 2026-09-29 and the tenant chart's same-namespace NetworkPolicy blocks the Traefik path, so nothing answers. Superseded by 15432 |
| 5433 | tcp | vcap-staging postgres (legacy path) | public | closed | same as 5432; superseded by 15433 |
| 15432 | tcp | vcap-dev postgres (OD-1's port) | public | **open** | TLS terminates at Traefik with the private-CA leaf, `pg_hba` refuses the bootstrap superuser over TCP, per-person roles are read-only, and an additive NetworkPolicy admits only Traefik. **Verified end-to-end from a client on 2026-09-29** (`sslmode=verify-full`, read allowed, write refused, superuser refused) |
| 15433 | tcp | vcap-staging postgres (OD-1's port) | public | **open** | same contract as 15432; opened **after** 15432 had been exercised, as the plan required, and verified end-to-end the same way |
| 7881 | tcp | kirro voice channel — LiveKit room server (WebRTC over TCP) | public | live | opened 2026-10-02 with the voice channel. The UDP fallback for callers whose network blocks UDP; `hostNetwork`, because WebRTC media cannot traverse Traefik. Authorised by the signalling room token, not by source IP |
| 7882 | udp | kirro voice channel — LiveKit room server (WebRTC media) | public | live | opened 2026-10-02. A single **muxed** UDP port (`rtc.udp_port`), not LiveKit's default 50000-60000 range — the reason this feature's internet-facing surface is two ports, not ten thousand |
| 30532 | tcp | vcap-staging postgres (dup NodePort) | public | removed | unmanaged, `kubectl apply`-created; deleted 2026-09-29 |
| 30533 | tcp | vcap-dev postgres (dup NodePort) | public | removed | unmanaged, `kubectl apply`-created; deleted 2026-09-29 |
| 30843 | tcp | traefik LB NodePort (web) | public | closed | kube-proxy auto-allocated, duplicates 80; no firewall rule, so dropped since 2026-09-28. Not removable while ServiceLB is in use |
| 30851 | tcp | traefik LB NodePort (websecure) | public | closed | kube-proxy auto-allocated, duplicates 443; no firewall rule, so dropped since 2026-09-28. Not removable while ServiceLB is in use |
| 32301 | tcp | traefik LB NodePort (postgres-dev) | public | removed | kube-proxy auto-allocated; deleted 2026-09-29 |
| 32131 | tcp | traefik LB NodePort (postgres-staging) | public | removed | kube-proxy auto-allocated; deleted 2026-09-29 |
| 6443 | tcp | k3s apiserver | public | remove | hostNetwork, **and the firewall allows it from `0.0.0.0/0`** — the kube-apiserver is genuinely reachable from the internet today. Closing it is N5, gated on the same tailnet prerequisite as 22 |
| 10250 | tcp | kubelet | public | closed | hostNetwork, still bound; no firewall rule, so unreachable from the internet since 2026-09-28. The tailnet row is the supported path |
| 2379 | tcp | etcd (client) | public | closed | 2-node cluster-init leftover, still bound on the public interface; no firewall rule, so dropped since 2026-09-28. N6's host firewall is what would unbind it |
| 2380 | tcp | etcd (peer) | public | closed | same as 2379 |
| 9100 | tcp | node-exporter | public | closed | **both layers landed**: the DaemonSet no longer sets `hostNetwork`, so it is not on the public IP at all, and the firewall has no rule for it either |
| 41641 | udp | tailscaled | public | live | required open for WireGuard NAT traversal |
| 8472 | udp | flannel VXLAN | public | closed | pod overlay, single node; bound for the overlay, no firewall rule, so dropped since 2026-09-28 |

Loopback-only ports (10248–10259, 6444, 2381–2382, 10010, 53) are not internet-reachable and are
omitted from this table — see the full audit in the architecture review §4 if needed.

**What the current-state table does not say: 80 and 443 accept traffic from *any* source, not only
Cloudflare.** Measured 2026-09-28 — `curl -sk --resolve argocd.upayan.dev:443:138.201.157.147
https://argocd.upayan.dev` returns `200`, and grafana `302`, straight from the origin; TCP 80, 443, 6443
and 22 all connect from an ordinary host. "Cloudflare-proxied" describes how legitimate traffic arrives,
not a restriction on who may arrive. The "from Cloudflare IP ranges only" row in the target table is
NET-003's work, and until it lands, Cloudflare Access would be bypassable by anyone who knows the origin
address — worth knowing before NET-003 is treated as defence in depth rather than as the only control.

## Target state (OD-1, not yet implemented)

| Port | Proto | Service | Scope | Notes |
|---|---|---|---|---|
| 80 | tcp | traefik (web) | public | from Cloudflare IP ranges only (Hetzner firewall) |
| 443 | tcp | traefik (websecure) | public | from Cloudflare IP ranges only |
| 15432 | tcp | vcap-dev postgres | public (**open**) | the public path — TLS termination at Traefik, per-person non-superuser roles. 5432 is closed and does not come back |
| 15433 | tcp | vcap-staging postgres | public (**open**) | same hardening; holds real (class A) student data, and was opened only after 15432 |
| 41641 | udp | tailscaled | public | unchanged |
| 22 | tcp | sshd | tailnet | no public rule; admin plane is tailnet-only |
| 6443 | tcp | k3s apiserver | tailnet | no public rule |
| 10250 | tcp | kubelet | tailnet | no public rule |

Everything else in the "current state" table above is closed by the Hetzner Cloud Firewall once the
network hardening lands. Note the asymmetry the two tables deliberately keep: **5432/5433 are closed
today and are not the target** — the target public path is 15432/15433, and neither is open yet (the
controls do not exist). See [`networking.md`](networking.md) for the firewall-layer design; §7 of the
architecture review (kept private, not published) holds the full target-architecture diagram.

## Measured external exposure (2026-09-28 — before 5432/5433 were closed)

Probed from the operator workstation against `138.201.157.147`, i.e. from the public internet. This
is a dated snapshot: since 2026-09-29 the Postgres path is closed (see the current-state table), so
5432/5433 no longer answer.

| Port | Service | Result |
|---|---|---|
| 22 | sshd (root login) | **OPEN** |
| 5432 | vcap-**dev** Postgres | was **OPEN** — **now closed** (NodePort deleted, tenant NetworkPolicy blocks the Traefik path) |
| 5433 | vcap-**staging** Postgres (holds student PII) | was **OPEN** — **now closed**, same |
| 15432 / 15433 | vcap Postgres (target path) | **closed** — nothing listens, no firewall rule (correct until the controls exist) |
| 30532 / 30533 / 30843 / 32301 | NodePort duplicates | filtered (firewalled, despite binding); all four deleted 2026-09-29 |
| 80 / 443 | Traefik | OPEN, expected (Cloudflare-proxied) |
| 6443 | k3s API server | **reachable** — `HTTP 401` on `/healthz`, so it answers unauthenticated probes |
| 2379 / 2380 | etcd client / peer | filtered (correctly firewalled off) |
| 10250 | kubelet | filtered (correctly firewalled off) |

So the firewall is doing more than the host's listener table suggests: etcd and kubelet bind the
public address but are unreachable from outside.

**The live exposure is 22, 80, 443 and 6443.** The database ports are no longer part of it: 5432/5433
were Traefik TCP passthrough over unmanaged `IngressRouteTCP` objects, and they serve nothing now. The
public path moves to **15432/15433**, and it stays shut until TLS, per-person non-superuser roles, a
network-superuser-locking `pg_hba`, the additive ingress policy and auth-failure alerting all exist —
none of them do today.
