# Architecture

Full detail: the architecture review (private, not published) §1 (current) and §7 (target). This
page summarizes both and tracks which parts of "target" are already true after S0.

## Historical state (2026-09-27, before S2 — superseded)

> **This block records what the cluster looked like when the review was written.** Do not use it as
> current state. For the current picture read the diagram's "What's now live" section at the end of
> this page, plus [`storage.md`](storage.md), [`backups.md`](backups.md) and [`certificates.md`](certificates.md).

```
Cloudflare (DNS + proxy, every *.upayan.dev record orange-clouded; codechefvit.com zone separate)
   │  HTTPS (origin presents Cloudflare Origin CA cert *.upayan.dev, exp 2027-09-28)
   ▼
Hetzner cx33 "vps" fsn1 — 138.201.157.147 / 2a01:4f8:c012:957::/64
   NO Hetzner Cloud Firewall · host iptables INPUT policy ACCEPT · ufw inactive · no fail2ban
   Ubuntu 24.04.5, kernel 6.8.0-142, unattended-upgrades on, Tailscale 100.96.250.81
   k3s v1.34.4+k3s1, embedded etcd (cluster-init leftover from 2-node era),
       flags: --node-ip=138.201.157.147 --node-external-ip=100.96.250.81 --flannel-iface=tailscale0
   ├─ k3s bundled: Traefik (HelmChart 38.0.2, patched by HelmChartConfig from git), CoreDNS,
   │  local-path provisioner, metrics-server, ServiceLB
   ├─ ArgoCD v2.14.11 self-managed, app-of-apps "root" → k8s/argocd/ (30 Applications)
   ├─ Platform: cert-manager (since removed, 2026-09-28), KEDA + http add-on, argocd-image-updater, hcloud-csi (manual sync),
   │  priority-classes, monitoring (Prometheus/Loki/Promtail/Grafana/KSM/node-exporter)
   ├─ Apps (apps project + vcap project; 3 charts from external repos)
   └─ Unmanaged: default/{keel,mochi,scamzap-web,gdsc-25-tasks,kodesphere(dup)},
      ns-68f3b786…-nginx, velero ns (stuck Job), hand-made TLS secrets, NodePort+IngressRouteTCP
      for vcap Postgres
Storage: root disk 75G ext4 (73% used in 2026-09-27) + 2× Hetzner 10G volumes via hcloud CSI (vcap dev/staging)
Backups: one-off manual bundle from S0 (see ../changelog/2026-09.md). No automation, no offsite R2 yet.
```

See [`inventory.md`](inventory.md) for exact IDs, [`storage.md`](storage.md) for the per-dataset
table, and [`ports.md`](ports.md) for the network surface.

## Target architecture (S2-S11 — see "What's now live" below for what is actually done)

```
                         Cloudflare (DNS, proxy, Full(strict), Always HTTPS, R2)
                                   │ 80/443 from CF IP ranges only
┌──────────────── Hetzner Cloud Firewall "vps" (Terraform) ─────────────────┐
│ in: tcp 80,443 ← Cloudflare ranges | udp 41641 ← any (Tailscale) | icmp   │
│ tcp 22 ← any (N5 restricts) | tcp 6443 ← any (N5 restricts)             │
└───────────────────────────────────────────────────────────────────────────┘
  vps (cx33) — Ubuntu 24.04 — Ansible-managed
   ├─ /            root disk: OS, k3s, images, Prometheus/Loki TSDB, logs, caches
   ├─ /srv/data    Hetzner volume "vps-data" (20 GB, ext4, delete-protected)
   │    └─ static hostPath PVs (retained vcap-v1, vcap-dev, vcap-staging, meghmitra; live adhigrahan-radar, gitorgasm)
   ├─ /var/lib/rancher/k3s/storage  local-path PVs (retained vcap-v1 app data, bitvault, rankstack, kirro)
   ├─ /var/backups/staging  dumps produced by the backup timer (root disk)
   ├─ vps-backup-class{A,C}.timer (30 min for class A, daily for C) → restic → R2 (bucket lock rule)
   ├─ Tailscale: the ONLY admin path (SSH, kubectl 6443). No database port is open (5432/5433 never reopen)
   └─ k3s (single server, embedded etcd, pinned version)
        ├─ ArgoCD (pinned chart) + repo-server with sops/ksops/helm-secrets (age key)
        ├─ platform: Traefik config (TLSStore default = Origin CA wildcard),
        │           KEDA, image-updater, priority-classes, storage (local-retain SC),
        │           monitoring (Prometheus, Grafana, Loki, Promtail, KSM, node-exporter)
        └─ apps: cas-api, adhigrahan-radar, gitorgasm, mochi, status-page, and other active apps
External: Cloudflare Access (ArgoCD, Grafana)
```

**Already removed** (2026-09-28): cert-manager (Traefik's default certificate is now the Origin CA
wildcard, SOPS-encrypted in git), keel, and the per-namespace `*-tls` Secrets. **Removed with the
2026-10-23 retirement**: the v2 Traefik Postgres entrypoints and routes, and the retired
workloads. **Still planned**: hcloud CSI driver (+ its in-cluster Hetzner token), unmanaged
NodePorts, duplicate/retired orphan apps, legacy TLS scripts, and the dead `docker/` stack
(archived). **Added**: nothing new in-cluster except ksops/helm-secrets inside the existing
repo-server pod; the host has restic and the backup scripts.

### What's already true after S0

- At S0, all 9 relevant dynamic PVs were `Retain` (not `Delete`) — see the changelog's 2026-09-27
  entry. Current reclaim policies differ by PV. See [`storage.md`](storage.md).
- A one-off backup bundle exists on the node and off-VM (workstation copy) — see
  [`backups.md`](backups.md).
- The TLS cutover (S7, 2026-09-28): Origin CA wildcard as Traefik's default certificate,
  cert-manager removed — see [`certificates.md`](certificates.md).

### What's now live (status as of 2026-10-27)

Everything in the target diagram above except the items listed at the end of this section is
**implemented and verified**. Per-stage detail lives in the linked docs and in
[`../changelog/2026-10.md`](../changelog/2026-10.md); the plan itself is
the architecture review (private, not published) §14/§17.

- **Terraform** (S2): server/IPs/SSH key/firewall/R2 buckets/Cloudflare zone settings imported and
  managed — the configuration is `terraform/` **in this repository** (see
  [`terraform/README.md`](../terraform/README.md)). `scripts/tf.sh` enforces this.
- **Ansible** (S3): host baseline, k3s config, `vps-data` mount, and the backup role applied from
  git; `admin_user` is the one role still unapplied (needs the owner's public key).
- **`vps-data` volume** (S8): 20 GB Hetzner volume mounted at `/srv/data`. The retained
  PostgreSQL datasets use static `Retain` PVs. The class-A set is `vcap-staging` (raw files) and
  the `gitorgasm` Postgres (logical dump). The retained `vcap-v1` trees are class C —
  [`storage.md`](storage.md).
- **SOPS/age** (S5): every `Secret` manifest under `k8s/` is `secrets.sops.yaml`, decrypted by a
  `ksops` generator in the repo-server. Rotation and the history rewrite are still outstanding —
  [`secrets.md`](secrets.md), [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md).
- **Network lockdown** (S11): per-namespace NetworkPolicies derived from observed traffic —
  [`networking.md`](networking.md).
- **Monitoring fixes** (S9) and **hardening** (S11): see below and
  [`monitoring.md`](monitoring.md).
- **Backups** (S4): automated on the node. Class A runs every 30 minutes. Class C runs daily. etcd
  snapshots run every 12 hours. The offsite `restic copy` to R2 runs hourly. Weekly prune and
  integrity checks run. Two monthly restore drills cover class A and class C. Staleness alerts
  cover both classes, etcd, offsite copy, restic check, and drills — [`backups.md`](backups.md).
- **Orphan cleanup** (S10) and the **dead `docker/` stack**: retired/archived.
- **Retirement** (2026-10-23): the v2, bitvault, rankstack, kirro, bandit, and upayan-v5
  workloads are removed. Their data, namespaces, Secrets, and retain policies remain.
- **vcap v1 retirement** (2026-10-27): the `vcap-v1` workloads, the `vcap` AppProject, the Postgres
  edge on TCP `15434`, and the firewall rule are removed. The data, Secrets, and ConfigMaps remain in
  namespace `vcap-v1`. See [`storage.md`](storage.md).
- **Portfolio API** (2026-10-25): `upayan-api` serves `api.upayan.dev` for the Vercel website.
  The retired `upayan-v5` namespace remains separate. The website does not run in this cluster.

**Still not implemented** (all owner-gated): credential rotation and the git-history rewrite (S5);
re-issuing the serving Origin certificate and revoking the old one (S7); the Hetzner firewall's final
rules; Cloudflare Access in front of ArgoCD/Grafana; and the external-VM restore drill (S12).

## Hardening posture (S11, 2026-09-28)

Two cluster-wide controls are now actually enforced, both verified against live state rather than
assumed:

**Pod Security Admission.** All active repo-owned app namespaces carry
`pod-security.kubernetes.io/enforce=baseline` plus `warn=restricted`. Before this they were
warn-only, so nothing stopped a privileged / host-network / hostPath / hostPort pod from being
scheduled into them. Each namespace was checked against the full Baseline control list — including
the v1.34 probe/lifecycle `host` control — before the flip, over all workload templates (not just
running pods, so KEDA scale-to-zero workloads were covered): zero violations. `monitoring` carries
explicit `privileged` labels (its TSDBs are `hostPath`, Prometheus is host-network); `kube-system`
is left unlabelled because `privileged` is what an unlabelled namespace already means and it is
k3s-owned, so a label would be untracked drift. The retained `vcap-dev` and `vcap-staging`
namespaces keep `warn` only. They have no workloads. `rankstack` is a retained namespace with no
workload and no live chart owner.

**AppProject scopes.** Each project (`apps`, `platform`) enumerates its destination
namespaces instead of `namespace: "*"`, and `platform` lists the 11 cluster-scoped kinds its apps
manage instead of `*`. Adding an app therefore also means adding its namespace to the `apps`
project — a deliberate review gate, and a loud failure (`namespace <x> is not permitted in project
<y>`) rather than a silent mis-sync. The `root` app has its own project too — `bootstrap`, scoped to
this repository, the `argocd` namespace and the three `argoproj.io` kinds under `k8s/argocd/` —
replacing the built-in `default`, which permits `'*'` everywhere and, being shared, made the other
projects' whitelists bypassable. The remaining step is mechanical rather than a design question:
`k8s/bootstrap/root-app.yaml` is not reconciled by ArgoCD, so the live `root` moves only when it is
re-applied by hand, and `AppProject/default` can be locked down only after that.

**Network policies** are covered in [`networking.md`](networking.md#networkpolicy-posture-s11--implemented-2026-09-28).
**Upgrade/pinning policy** is in [`upgrade-policy.md`](upgrade-policy.md).

## Ownership model (target)

One owner per resource, enforced so Terraform/Ansible/k3s/ArgoCD never fight over the same object.
Full table: [`maintenance.md`](maintenance.md#ownership-model). The split is live: Ansible owns the
host (this repo's `ansible/`) and Terraform owns the provider layer, in the `cluster` checkout
(`cluster/terraform/`).
