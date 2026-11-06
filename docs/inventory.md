# Machine inventory

Factual reference sheet — "what is this machine, exactly." Source: §1 and §2.1 of the architecture
review (kept private, not published). Hetzner rows use `terraform/` as the source. Host and storage
facts were checked on 2026-10-23 with `ssh` and `kubectl` read commands.

## Hetzner project

| Resource | ID / value | Notes |
|---|---|---|
| Server `vps` | 122385524, cx33, fsn1, created 2026-02-28 | Hetzner server backup off. Delete and rebuild protection on. Firewall `vps` (11692068) attached 2026-09-28. Declared in `terraform/hcloud.tf`. |
| Primary IPv4 | 138.201.157.147 | `auto_delete=false` and delete protection on, so the address survives a server rebuild. |
| Primary IPv6 | 2a01:4f8:c012:957::/64 | `auto_delete=false` and delete protection on. |
| Volume `vps-data` | 106969476, Terraform-managed, 20 GB | Attached as `/dev/sdb` and mounted at `/srv/data`. Delete protection on. The static `hostPath` PVs use this volume. |
| Legacy volume 106574315 (staging) and 106574316 (dev) | two 10 GB hcloud CSI volumes | No PV references them. The data moved to `/srv/data`. Teardown is pending. |
| Legacy volume 106353532 | **does not exist** | No PV references it. The former `smart-home-system-api` Hetzner CSI volume is gone. Two local-path PVCs for that app remain bound in `default` and `smart-home-system-api`. The Deployment is scaled to zero. The loss is deliberate and owner-confirmed. See [`storage.md`](storage.md). |
| Firewall `vps` | 11692068 | Attached 2026-09-28. The repository declares tcp/22, tcp/80, tcp/443, tcp/6443, udp/41641, and icmp. TCP 80 and 443 use Cloudflare ranges while `cloudflare_only_ingress` is true. TCP 15434 was removed and applied on 2026-10-27. No database port is open. Live rules can lag until Terraform applies `firewall.tf`. See [`networking.md`](networking.md). |
| R2 buckets | `vps-backups`, `vps-tfstate` | Offsite restic snapshots and Terraform state. Location WEUR. No versioning. |
| Networks, load balancers, floating IPs, snapshots | none | The Kubernetes API uses a host port. |
| SSH keys (Hetzner project) | `vps-root`, and the owner's personal key (its name is an address — held privately) | |

## k3s

| Field | Value |
|---|---|
| Version | `v1.34.4+k3s1` |
| Topology | single server, embedded etcd (`cluster-init` leftover from a since-removed 2-node era — the second node was removed, see the stale-reference cleanup below)
| Flags | `--tls-san vps.upayan.dev`, `--node-ip=138.201.157.147`, `--node-external-ip=100.96.250.81`, `--flannel-iface=tailscale0` |
| Node name | `vps` |
| Bootstrap | `k8s/bootstrap/root-app.yaml`, applied once by hand — see `k8s/bootstrap/README.md` |

## Host

| Field | Value |
|---|---|
| OS | Ubuntu 24.04.5, kernel 6.8.0-142 |
| Public IPv4 | 138.201.157.147 |
| Public IPv6 | 2a01:4f8:c012:957::/64 |
| Tailscale IP | 100.96.250.81 |
| Disk | 75 GB root (ext4), 64% used as of 2026-10-23. A 20 GB data volume is mounted at `/srv/data`, 3% used. |
| Patching | `unattended-upgrades` on (OS packages only, no cadence beyond that — see `upgrade-policy.md`) |

## Cloudflare

| Field | Value |
|---|---|
| Zone | `upayan.dev` (every record orange-clouded/proxied) |
| SSL mode | Full (strict), already set, owner-confirmed |
| Out of scope | `codechefvit.com` zone (someone else's) |
| Target-managed by | Terraform, only if the import plan is zero-diff (S2) |

## Batch Autopsy application

- **GitOps registration:** explicit Application
  `k8s/argocd/applications/apps/batch-autopsy.yaml`, project `apps`, namespace `batch-autopsy`.
  This is a two-image workload, not an ApplicationSet member.
- **Public routes:** `https://batch-autopsy.upayan.dev` serves the web application.
  `https://api-batch-autopsy.upayan.dev/docs` serves the API documentation.
  The web application also proxies same-origin `/api` requests to the API Service.
  Existing Cloudflare DNS resolves both hosts. Traefik uses the wildcard Origin CA certificate.
- **Access decision:** the owner explicitly requested open access without Cloudflare Access.
  No login, identity policy or authenticated signature is added. Visitors can inspect and modify
  shared records and invoke any configured AI provider. Use fictional data only.
- **Workloads:** API on `api:8000`, web on `web:8080`, PostgreSQL 18.6 on `postgres:5432`.
  All Services remain ClusterIP. The database stays private.
- **Network boundary:** default-deny ingress and egress remain active.
  Public ingress policies permit only labelled Traefik pods in `kube-system` to reach web TCP/8080
  and API TCP/8000. Existing web-to-API, API-to-Postgres and CoreDNS allowances remain unchanged.
  The API permits public IPv4 TCP/443 for Groq. Standard NetworkPolicy cannot enforce Groq's FQDN.
- **Secrets:** ksops consumes `k8s/apps/batch-autopsy/secrets.sops.yaml`.
  It holds `batch-autopsy-db` and `ghcr-batch-autopsy`. The latter copies the approved private
  registry credential without changing its permissions. Rotate the copy when its source rotates.
  `batch-autopsy-ai` holds the dedicated Groq key, referenced only by the API environment.
  The key expires on 6 December 2026. Renew it through the provider and encrypted GitOps workflow.
  The local development copy is ignored by Git and restricted to mode `0600`.
- **Provider schema mode:** the deployment uses `GROQ_STRICT=false` after a real strict-mode
  `json_validate_failed` response. Pydantic validation, source quote verification and the existing
  bounded repair remain active. Model and application retry policy are unchanged.
- **Resources:** one replica per workload, pinned to `vps`, `low-priority`, non-root,
  read-only roots, dropped capabilities, RuntimeDefault seccomp and no service-account token mount.
  Requests total **225m CPU / 416 MiB RAM**. Limits total **1100m CPU / 832 MiB RAM**.
  Concurrent API/web rolling surges can add **125m / 288 MiB** requests and **600m / 576 MiB** limits.
- **Storage/cost:** the retained 2 Gi claim uses `/srv/data/batch-autopsy-postgres` on the existing
  volume. Ansible provisioned mode `0700` and owner/group `70:70`.
  No new server, volume or IP is required. Backup integration remains absent.
  See [storage.md](storage.md#batch-autopsy-dataset).
- **Verified private baseline:** deployment PR #88 merged after all seven required checks.
  ArgoCD reported Synced/Healthy. Separate rollout waits confirmed all three workloads ready.
  The retained claim bound. Browser checks confirmed creation, saved-title reload and text ingestion.
  Public PR #90 then passed all seven checks and merged as `8309a65`.
  Both public hosts responded over HTTPS. Thorium loaded the workbench without a login gate.

Changes require protected pull requests. ArgoCD applies Kubernetes state.
Rollback uses a reviewed GitOps revert. Retained data is not erased automatically.

## Contacts

Roles are here because they are what the cluster's access model is built on; **names and addresses are held
privately** (the owner's password manager, mirrored in the repository's private notes) so that this document
can be published without carrying personal data. Delete the private copy once it is in the password manager.

| Role | Access |
|---|---|
| Owner / admin | Tailnet (SSH, kubectl), Cloudflare Access allow-list, only tailnet identity in the target design |
| VCAP v1 tenant | None. vcap v1 was retired on 2026-10-27. No public database access exists. |

## Related

- [`architecture.md`](architecture.md) — how these pieces fit together, current and target
- [`storage.md`](storage.md) — what is on the data volume, the local-path PVs, and the root disk
- [`ports.md`](ports.md) — what's reachable on this machine and from where
