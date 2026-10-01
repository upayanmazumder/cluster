# Architecture

Full detail: the architecture review (private, not published) §1 (current) and §7 (target). This
page summarizes both and tracks which parts of "target" are already true after S0.

## Current state (as of 2026-09-27 — a dated snapshot, now largely superseded)

> **This block records what the cluster looked like when the review was written.** Most of it has
> changed; for the current picture read the diagram's "What's now live" section at the end of this
> page, plus [`storage.md`](storage.md), [`backups.md`](backups.md) and [`certificates.md`](certificates.md).

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
Storage: root disk 75G ext4 (73% used) + 2× Hetzner 10G volumes via hcloud CSI (vcap dev/staging)
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
│ tcp 15432,15433 ← any (vcap Postgres, TLS) | tcp 22 ← any (N5 restricts)  │
└───────────────────────────────────────────────────────────────────────────┘
  vps (cx33) — Ubuntu 24.04 — Ansible-managed
   ├─ /            root disk: OS, k3s, images, Prometheus/Loki TSDB, logs, caches
   ├─ /srv/data    Hetzner volume "vps-data" (20 GB, ext4, delete-protected)
   │    └─ k8s/    local-path default path → protected PVs (vcap-*, meghmitra) + all new PVs
   ├─ /var/backups/staging  dumps produced by the backup timer (root disk)
   ├─ vps-backup.timer (30 min for class A, daily for C) → restic → R2 (bucket lock rule)
   ├─ Tailscale: the ONLY admin path (SSH, kubectl 6443). vcap Postgres target is 15432/15433 (closed today; 5432/5433 never reopen)
   └─ k3s (single server, embedded etcd, pinned version)
        ├─ ArgoCD (pinned chart) + repo-server with sops/ksops/helm-secrets (age key)
        ├─ platform: Traefik config (TLSStore default = Origin CA wildcard),
        │           KEDA, image-updater, priority-classes, storage (local-retain SC),
        │           monitoring (Prometheus, Grafana, Loki, Promtail, KSM, node-exporter)
        └─ apps: de/*, sg/*, vcap/*, external-chart apps
External: healthchecks.io (dead-man's switch for backups + Prometheus watchdog);
Cloudflare Access (ArgoCD, Grafana; bypass for the two vcap public-dashboard paths)
```

**Already removed** (2026-09-28): cert-manager (Traefik's default certificate is now the Origin CA
wildcard, SOPS-encrypted in git), keel, and the per-namespace `*-tls` Secrets. **Removed** in the
target state: hcloud CSI driver (+ its in-cluster Hetzner token), Traefik Postgres TCP entrypoints,
unmanaged NodePorts, duplicate/retired orphan apps, legacy TLS scripts, dead `docker/` stack
(archived). **Added**: nothing new in-cluster except ksops/helm-secrets inside the existing
repo-server pod; the host gains restic + one backup script.

### What's already true after S0

- All 9 relevant dynamic PVs are `Retain` (not `Delete`) — see the changelog's 2026-09-27 entry.
- A one-off backup bundle exists on the node and off-VM (workstation copy) — see
  [`backups.md`](backups.md).
- The TLS cutover (S7, 2026-09-28): Origin CA wildcard as Traefik's default certificate,
  cert-manager removed — see [`certificates.md`](certificates.md).

### What's now live (status as of 2026-09-28)

Everything in the target diagram above except the items listed at the end of this section is
**implemented and verified**. Per-stage detail lives in the linked docs and in
[`../changelog/2026-09.md`](../changelog/2026-09.md); the plan itself is
the architecture review (private, not published) §14/§17.

- **Terraform** (S2): server/IPs/SSH key/firewall/R2 buckets/Cloudflare zone settings imported and
  managed — the configuration is `terraform/` **in this repository** (see
  [`terraform/README.md`](../terraform/README.md)). This line used to call it "a pointer" to a
  separate `cluster` checkout, which was true of the private `vps` tree this was exported from and
  has not been true of `cluster` itself; `scripts/tf.sh` enforces the same thing by refusing to run
  from any other origin.
- **Ansible** (S3): host baseline, k3s config, `vps-data` mount, and the backup role applied from
  git; `admin_user` is the one role still unapplied (needs the owner's public key).
- **`vps-data` volume** (S8): 20 GB Hetzner volume mounted at `/srv/data`, and the three class-A
  datasets moved onto static `Retain` PVs — [`storage.md`](storage.md).
- **SOPS/age** (S5): every `Secret` manifest under `k8s/` is `secrets.sops.yaml`, decrypted by a
  `ksops` generator in the repo-server. Rotation and the history rewrite are still outstanding —
  [`secrets.md`](secrets.md), [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md).
- **Network lockdown** (S11): per-namespace NetworkPolicies derived from observed traffic —
  [`networking.md`](networking.md).
- **Monitoring fixes** (S9) and **hardening** (S11): see below and
  [`monitoring.md`](monitoring.md).
- **Backups** (S4): automated on the node (class A 15-min, class C daily, etcd 12h, weekly prune,
  weekly integrity check, monthly restore drill that *imports* the dumps), with five scraped metrics
  and five staleness alerts. The restic repository is the **interim local
  `/var/backups/restic`** — the R2 offsite leg needs R2 credentials and is the remaining S4 gate —
  [`backups.md`](backups.md).
- **Orphan cleanup** (S10) and the **dead `docker/` stack**: retired/archived.

**Still not implemented** (all owner-gated): the R2 offsite backup leg; credential rotation and the
git-history rewrite (S5); the vcap Postgres exposure change + per-person DB roles (S6); re-issuing
the serving Origin certificate and revoking the old one (S7); the Hetzner firewall's final rules
(S6 — Terraform holds a deliberately permissive firewall today); Cloudflare Access in front of
ArgoCD/Grafana; healthchecks.io dead-man switches; the throwaway-VM restore drill (S12).

## Hardening posture (S11, 2026-09-28)

Two cluster-wide controls are now actually enforced, both verified against live state rather than
assumed:

**Pod Security Admission.** All 15 repo-owned app namespaces carry
`pod-security.kubernetes.io/enforce=baseline` plus `warn=restricted`. Before this they were
warn-only, so nothing stopped a privileged / host-network / hostPath / hostPort pod from being
scheduled into them. Each namespace was checked against the full Baseline control list — including
the v1.34 probe/lifecycle `host` control — before the flip, over all workload templates (not just
running pods, so KEDA scale-to-zero workloads were covered): zero violations. `monitoring` carries
explicit `privileged` labels (its TSDBs are `hostPath`, Prometheus is host-network); `kube-system`
is left unlabelled because `privileged` is what an unlabelled namespace already means and it is
k3s-owned, so a label would be untracked drift. `vcap-dev`/`vcap-staging` get `warn` only, via
ArgoCD `managedNamespaceMetadata` — enforcing Baseline there would block §S6's planned
`postgres.hostPort`, since `hostPort` is itself a Baseline violation. `rankstack`'s labels live in
its own chart (`upayanmazumder/rankstack#94`) because that chart owns the namespace.

**AppProject scopes.** Each project (`apps`, `vcap`, `platform`) enumerates its destination
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
