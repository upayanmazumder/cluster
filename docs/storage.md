# Storage

This page describes the live storage layout after the 2026-10-23 retirement. Verify live state
before you rely on any number here.

## Live data

| Dataset | Namespace | Backing | Size | Backup |
| --- | --- | --- | --- | --- |
| Postgres `vcap-v1` | `vcap-v1` | static PV `vcap-v1-postgres-data-vps`, hostPath `/srv/data/vcap-v1-postgres`, `Retain` | 67 MB | class A logical dump |
| Application data `vcap-v1` | `vcap-v1` | local-path PV `pvc-d4b91391-4691-43c4-9590-6bbe1ddf0ad9`, `Delete` | 15 MB | class A raw |
| Postgres and MinIO `vcap-staging` | `vcap-staging` | static PV `vcap-backend-staging-data-vps`, hostPath `/srv/data/vcap-staging`, `Retain` | 75 MB | class A raw |
| Postgres and MinIO `vcap-dev` | `vcap-dev` | static PV `vcap-backend-dev-data-vps`, hostPath `/srv/data/vcap-dev`, `Retain` | 70 MB | class C raw |
| Postgres `meghmitra` | `meghmitra` | static PV `meghmitra-postgres-pvc-vps`, hostPath `/srv/data/meghmitra-postgres`, `Retain` | 206 MB | class C raw |
| Postgres and MinIO `bitvault` | `bitvault` | local-path PVs `pvc-4f59ae33…` and `pvc-acbed98f…`, `Retain` | 48 MB + 148 KB | class C raw |
| Mongo `rankstack` | `rankstack` | local-path PV `pvc-fb2fad5e…`, `Retain` | 509 MB | class C raw |
| Mock service data `kirro` | `kirro` | local-path PV `pvc-623ce531…`, `Delete` | 76 MB | class C raw |
| Voice logs `kirro` | `kirro` | local-path PV `pvc-905a8d2c…`, `Delete` | 456 KB | class C raw |
| SQLite and model data | `adhigrahan-radar` | static PV `adhigrahan-radar-data-pvc-vps`, hostPath `/srv/data/adhigrahan-radar-data`, `Retain` | 23 MB | class C raw plus consistent `vivaad.db` copy |
| Corpus | `meghmitra` | local-path PV `pvc-a5b3a672…`, `Retain` | 4 KB | none |
| Grafana | `monitoring` | PV `pv-grafana`, hostPath `/var/lib/k8s-monitoring/grafana`, `Retain` | 52 MB | class C raw plus consistent `grafana.db` copy |

The `vcap-staging`, `vcap-dev`, `bitvault`, `rankstack`, and `kirro` workloads are gone. Their
namespaces, PVCs, PVs, Secrets, and data remain. Their Postgres and Mongo trees are static. Do not
start a server on a retained tree. Copy it first. See the restore runbooks.

The `meghmitra` Postgres workload is also gone. The data remains. The `adhigrahan-radar` workload
replaced the old meghmitra application and is live.

## Disposable and infrastructure data

| Dataset | Backing | Size | Backup |
| --- | --- | --- | --- |
| Prometheus TSDB | PV `pv-prometheus`, `/var/lib/k8s-monitoring/prometheus`, `Retain` | 3.8 GB | none |
| Loki chunks | PV `pv-loki`, `/var/lib/k8s-monitoring/loki`, `Retain` | 3.4 GB | none |
| etcd | `/var/lib/rancher/k3s/server/db` | 546 MB | restic `--tag etcd`, 5 local + 14 offsite |
| k3s token and TLS | `/var/lib/rancher/k3s/server/{token,tls}` | 216 KB | same restic snapshot as etcd |

Prometheus and Loki are disposable. Their loss does not affect an application dataset.

## Space

Measured 2026-10-23:

- Root disk: 75 GB ext4, 46 GB used, 27 GB free, 64%.
- `/srv/data`: 20 GB ext4, 439 MB used, 19 GB free, 3%.
- Class A source data: about 157 MB. This is `/srv/data/vcap-staging` (75 MB), the `vcap-v1`
  Postgres tree (67 MB), and the `vcap-v1` application data (15 MB). The class-A snapshot also
  contains the logical dump and globals.
- The largest single dataset is `rankstack` at 509 MB, followed by `meghmitra-postgres` at 206 MB.

## Storage configuration

- `local-path` is the default StorageClass. It provisions under
  `/var/lib/rancher/k3s/storage`. The StorageClass default reclaim policy is `Delete`. Individual
  PVs can differ: the bitvault and rankstack PVs are `Retain`, while the kirro and `vcap-v1`
  application-data PVs are `Delete`.
- `hcloud-volumes` exists but has no PVs. No Hetzner CSI volume backs a PVC. The driver is not on a
  critical path.
- Static PVs use `hostPath`, not `.spec.local`. The path is in `.spec.hostPath.path`. All static
  PVs use `Retain` and pin to node `vps`.
- The monitoring PVs use the `hostpath-retain` class and point under `/var/lib/k8s-monitoring`.

## Backup coverage

Class A runs every 30 minutes. Class C runs daily. See [`backups.md`](backups.md) for the exact
targets and retention.

- `vcap-v1` Postgres is a logical target. It runs `pg_dump -Fc` and `pg_dumpall --globals-only`
  inside the live pod. A raw copy of a running Postgres tree can be inconsistent.
- `vcap-staging` is a class-A raw target. Its Postgres and MinIO data are static.
- `vcap-v1` application data is a class-A raw target. The PVC uses `Delete`, so the backup is the
  only copy outside the node.
- Class C covers `vcap-dev`, `adhigrahan-radar`, `meghmitra-postgres`, both bitvault PVCs,
  `rankstack`, both kirro PVCs, and Grafana.
- Class C is best effort. The owner accepts loss of class-C data.

Not backed up:

- `meghmitra-corpus-pvc`: 4 KB and effectively empty. The corpus is re-downloadable.
- `meghmitra-data-pvc`: it is empty and has no backup target. See below.
- Prometheus and Loki: disposable monitoring data.

## Known gaps

### `meghmitra-data-pvc` is empty

PV `meghmitra-data-pvc-vps` is `Bound` and claims hostPath `/srv/data/meghmitra-data`. The directory
exists. The Ansible `data_volume` role created it on 2026-10-23. It is empty. The PVC has no
recoverable content. Do not delete the PVC or the PV. The binding records the configured intent,
and a future restoration may write data to the path. No backup target exists for it because there
is no data to read.

### `smart-home-system-api` is out of this inventory

The deployment is scaled to zero by KEDA. It has a PVC in both its own namespace and `default`.
This predates the retirement. Leave it alone unless a separate task takes it.

## Historical notes

- On 2026-09-28, `vcap-staging`, `vcap-dev`, and `meghmitra` Postgres moved to static PVs on
  `vps-data`. The old Hetzner CSI volumes `106574315` and `106574316` are gone. The 14-day rollback
  window closed on 2026-10-12. Do not plan around those volumes.
- The old rankstack measurement of 369 MB allocated with 0 documents and 5 collections described
  the running database on 2026-09-28. It is historical. The current tree is 509 MB of static
  WiredTiger files.
- The old `meghmitra` database size of 215 MB described the running database. The current raw tree
  is 206 MB.
- The class-A composition changed on 2026-10-23: `vcap-staging` and `meghmitra` logical dumps were
  replaced by raw file targets. `vcap-v1` remains the only logical Postgres target.

## Related

- [`backups.md`](backups.md) — backup targets, retention, and restore drills
- [`runbooks/restore-postgres.md`](runbooks/restore-postgres.md)
- [`runbooks/restore-mongo.md`](runbooks/restore-mongo.md)
- [`runbooks/restore-minio.md`](runbooks/restore-minio.md)
- [`disaster-recovery.md`](disaster-recovery.md)
