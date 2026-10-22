# `vps` cluster docs

Operational documentation for the `vps` k3s cluster on Hetzner DE.
It describes the live cluster on 2026-10-23.
The architecture programme that created the cluster is closed.
Its plan is not part of this tree.

Current state:

- ArgoCD applies the GitOps tree in `k8s/`.
- Fourteen application Applications run: eight list-generated apps, four explicit apps, and two `vcap-v1` Applications. Platform Applications are separate.
- The retired v2 workloads `vcap-dev` and `vcap-staging` have no Deployments, Services, or routes.
- Seven retained PVCs and PVs hold data from retired workloads.
- Eight backup timers run on the host.
- Twelve backup targets are registered: 3 class A and 9 class C.
- An hourly offsite copy goes to Cloudflare R2 bucket `vps-backups`.
- Only `vcap-v1` serves `vcap.upayan.dev` and `api-vcap.upayan.dev`.
- The public vcap Postgres edge uses TCP `15434` and TLS.

## Never delete casually

This cluster holds real data. Automated backups exist. Read [`backups.md`](backups.md) before
any deletion. The node-local restic repository is on the root disk. Loss of the server loses that
copy. The R2 offsite copy is the durable copy. Treat these actions as irreversible:

- **PVC or PV deletion.** A dynamic PV with `reclaimPolicy: Delete` destroys the volume at once.
  The retained dataset PVs use `Retain`. The `kirro` PVs and the `vcap-v1` application-data PV use
  `Delete`. Check the reclaim policy first:
  `kubectl get pv -o custom-columns=N:.metadata.name,R:.spec.persistentVolumeReclaimPolicy`.
- **Hetzner volume deletion.** A volume deletion is immediate. No per-volume snapshot exists.
- **Hetzner server or primary IP deletion.** Terraform sets delete protection, rebuild
  protection, `auto_delete=false`, and `prevent_destroy`. Do not remove these guards.
  An IP deletion forces a DNS change for every record.
- **Restic or etcd snapshot pruning.** The scripts own the retention schedule. A manual
  `restic forget --prune` removes recovery points. The R2 copy and the workstation mirror are
  independent copies. They are not replacements for the repository.
- **Secret deletion.** Confirm a tested recovery path first. Find every consumer before a
  rotation.
- **Git history rewrite.** No rewrite is planned. Never force-push without written owner
  approval.
- **Blind ArgoCD prune.** Enable `prune: true` only after you verify ownership of every object.
- **Formatting a disk, reinstalling k3s over data, or destroying Terraform infrastructure.**
  Confirm with the owner first.

If in doubt, stop. Read [`disaster-recovery.md`](disaster-recovery.md) and the matching runbook
under [`runbooks/`](runbooks/). Confirm with the owner before a destructive action.

## Index

| Doc | Covers |
|---|---|
| [`architecture.md`](architecture.md) | Current architecture, ownership model, and remaining target work |
| [`adr/`](adr/README.md) | Architecture Decision Records: status, context, rejected alternatives, and consequences (nine records) |
| [`inventory.md`](inventory.md) | Machine sheet: server, IP, volume IDs, k3s version, contacts |
| [`storage.md`](storage.md) | Live dataset inventory, paths, sizes, reclaim policies, backup coverage |
| [`backups.md`](backups.md) | Backup timers, 12 targets, restic repository, offsite copy, drill |
| [`disaster-recovery.md`](disaster-recovery.md) | Failure scenarios, RPO, current recovery paths |
| [`ports.md`](ports.md) | Port registry (source: [`../inventory/ports.yaml`](../inventory/ports.yaml)) |
| [`networking.md`](networking.md) | Firewall, Tailscale, Cloudflare, and public exposure |
| [`secrets.md`](secrets.md) | SOPS scope, Secret inventory, and remaining live-only Secrets |
| [`certificates.md`](certificates.md) | Three live TLS Secrets and certificate rotation |
| [`monitoring.md`](monitoring.md) | Prometheus, Grafana, Loki, dashboards, and 29 alert rules |
| [`maintenance.md`](maintenance.md) | Routine tasks, disk hygiene, ownership rules |
| [`upgrade-policy.md`](upgrade-policy.md) | Upgrade cadence for OS, k3s, ArgoCD, and charts |
| [`runbooks/restore-postgres.md`](runbooks/restore-postgres.md) | Restore `vcap-v1` from a dump, or start a retained Postgres tree for export |
| [`runbooks/restore-mongo.md`](runbooks/restore-mongo.md) | Recover retained rankstack Mongo data |
| [`runbooks/restore-minio.md`](runbooks/restore-minio.md) | Recover retained MinIO trees from `vcap-dev`, `vcap-staging`, or bitvault |
| [`runbooks/recover-k3s.md`](runbooks/recover-k3s.md) | Restore k3s and etcd from a snapshot |
| [`runbooks/recover-vm.md`](runbooks/recover-vm.md) | Full VM loss recovery |
| [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md) | Current secret rotation procedures |
| [`runbooks/rotate-certificates.md`](runbooks/rotate-certificates.md) | Wildcard and vcap v1 edge certificate rotation |
| [`runbooks/vcap-postgres-access.md`](runbooks/vcap-postgres-access.md) | Retired v2 access notice |
| [`runbooks/vcap-v1-postgres-access.md`](runbooks/vcap-v1-postgres-access.md) | vcap v1 public Postgres edge, CA, and client setup |
| [`runbooks/add-port.md`](runbooks/add-port.md) | Add an externally reachable port |
| [`runbooks/ingest-corpus.md`](runbooks/ingest-corpus.md) | Ingest a corpus into the retained corpus store |

## Related

- [`../changelog/`](../changelog/): dated record of every cluster change
- [`../AGENTS.md`](../AGENTS.md): repository conventions
- [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md): hard rules for cluster changes
