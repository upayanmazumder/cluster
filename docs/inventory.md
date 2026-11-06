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

## Batch Autopsy private application (prepared, not yet activated)

- **GitOps registration:** explicit Application
  `k8s/argocd/applications/apps/batch-autopsy.yaml`, project `apps`, namespace `batch-autopsy`.
  This is a two-image workload, not an ApplicationSet member.
- **Workloads:** API on `api:8000`, web on `web:8080`, PostgreSQL 18.6 on `postgres:5432`.
  All Services are ClusterIP, with a headless database Service; no Ingress, NodePort, LoadBalancer,
  public DNS, public TLS route, or new authentication feature is introduced.
- **Access:** an authorized cluster operator can run
  `kubectl -n batch-autopsy port-forward --address 127.0.0.1 svc/web 8080:8080`
  and open `http://127.0.0.1:8080`. The web server proxies `/api` internally.
  The application has no authentication and must not be exposed publicly without separate approval.
- **Network boundary:** default-deny ingress and egress; only web-to-API TCP/8000,
  API-to-Postgres TCP/5432, and API/web DNS to labelled CoreDNS pods are permitted.
  The API additionally permits public IPv4 TCP/443 for Groq. Standard Kubernetes NetworkPolicy
  cannot express a Groq FQDN allowlist: this rule excludes private, loopback, link-local, tailnet,
  multicast/reserved and node ranges, but it is **not** a Groq-only hostname restriction.
  An FQDN-aware egress proxy/CNI would be a separate infrastructure change.
- **Secrets:** `k8s/apps/batch-autopsy/secrets.sops.yaml`, consumed by ksops, holds
  `batch-autopsy-db` (fresh random password and matching DATABASE_URL) and `ghcr-batch-autopsy`
  (a namespaced copy of the approved cluster-managed GHCR credential).
  Neither token permissions nor GitHub account settings change. Rotate the namespaced copy when
  the source credential rotates. No Groq key or fake key is present; AI calls remain unavailable
  until an owner-approved key is added to an encrypted Secret and referenced by the API.
- **Resources:** one replica per workload, pinned to `vps`, `low-priority`, non-root,
  read-only root filesystems, dropped capabilities, RuntimeDefault seccomp and no service-account
  token mount. Requests total **225m CPU / 416 MiB RAM**; limits total **1100m CPU / 832 MiB RAM**.
  Default rolling updates can temporarily add **125m / 288 MiB** requests and
  **600m / 576 MiB** limits if both Deployments surge. PostgreSQL does not surge.
  `/tmp`, PostgreSQL's runtime socket and shared-memory paths are bounded ephemeral mounts.
- **Storage/cost:** one static 2 Gi Retain PV on the existing `/srv/data` filesystem, no new billed
  volume/server/IP. See [storage.md](storage.md#batch-autopsy-dataset-declared-activation-pending)
  for provisioning and backup limitations. No Groq billing change is authorized.

### Activation sequence

1. Finish private source-repository CI publication of both `:main` images and replace the temporary
   app image tags in `k8s/apps/batch-autopsy/kustomization.yaml` with their actual manifest digests.
   Verify the existing GHCR credential can read both private packages; do not make packages public.
2. Provision only the new host directory through the existing Ansible `data_volume` role.
   Confirm the mounted filesystem, ownership and free space before allowing reconciliation.
3. Run the repository validation suite, including ksops rendering without disclosing decrypted
   Secret values; commit these manifests, inventory and changelog together on the feature branch.
   Open a PR and merge only after the protected-main checks pass.
4. Root ArgoCD discovers the explicit Application after merge. The shared namespace baseline,
   secrets, Services, policies and healthy Postgres reconcile before API/web (sync wave 1).
   Confirm Synced/Healthy, bound PV/PVC and all three Ready pods using read-only kubectl.
5. Use the loopback-only port-forward for the product smoke check. Image Updater tracks API/web
   aliases independently and writes digest updates with `git:secret:argocd/git-creds-updater`.
   A later Groq key addition requires a separate encrypted GitOps change; no key is required for
   source ingestion, manual review and persisted investigations.

Rollback is a reviewed GitOps revert. PV/PVC and Namespace are protected from automatic
deletion/pruning, so reverting workload registration is not a data-erasure procedure.

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
