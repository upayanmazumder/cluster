# backup role

Deploys the host-level backup scripts, the target registry, and eight systemd timers. It installs
`restic`, `jq`, `yq`, and `sqlite3`. It renders `/etc/vps-backup/env` (mode 0600, `no_log`) from
SOPS-encrypted group vars.

The role does **not** run `restic init` and does **not** enable or start any timer. Both are separate
operator steps.

## What runs on `vps`

| Unit | Schedule | Purpose |
| --- | --- | --- |
| `vps-backup-classA.timer` | every 30 min | class-A dump or raw file backup |
| `vps-backup-classC.timer` | daily | class-C raw file backup |
| `vps-etcd-snapshot.timer` | every 12 h | etcd snapshot, k3s token, TLS, `/etc/rancher/k3s` |
| `vps-backup-offsite.timer` | hourly | `restic copy` of every tag to R2 |
| `vps-backup-prune.timer` | Monday 03:00 UTC | retention on the local repository |
| `vps-restic-check.timer` | Sunday 04:00 UTC | `restic check --read-data-subset=10%` |
| `vps-restore-test.timer` | 1st at 05:00 UTC | class-A restore drill |
| `vps-restore-test-c.timer` | 15th at 06:00 UTC | class-C restore drill |

The local repository is `/var/backups/restic`. The offsite repository is Cloudflare R2 bucket
`vps-backups`. As of 2026-10-23 all eight timers are enabled. The offsite copy is live. Its metric
file `vps_backup_offsite.prom` receives `vps_backup_offsite_last_success_timestamp` after each
successful copy.

Class A holds two targets: `vcap-staging` (raw `file`) and `gitorgasm` Postgres (logical dump).
The vcap v1 Postgres raw directory, the vcap v1 app-data directory, and the final dump directory
are class C `file` targets. vcap v1 was retired on 2026-10-27. It is no longer a logical `postgres`
dump. Every retired Postgres and Mongo dataset is a raw `file` target because no server runs on it.
Read `files/backup-targets.yaml` for the exact target list and sizes. Class C includes the 509 MB rankstack tree.

Each run clears its class staging tree before it dumps. It holds a per-class lock for the whole run.
A target removed from the registry therefore stops entering new snapshots.

`vps-restore-test.sh` creates a scratch pod for class A on the 1st. It creates one for class C on the
15th. The two runs must not overlap. Each run takes the drill lock
`/var/lock/vps-restore-test.lock`.

## Run the playbook

Run from `ansible/`. `ansible/ansible.cfg` enables the `community.sops` vars plugin. Ansible reads a
cwd `ansible.cfg` only. From the repository root the SOPS values stay encrypted. On 2026-09-28 that
wrote `ENC[AES256_GCM,…]` as the restic password and broke class-A backups. The role now asserts
against it, but the correct invocation is:

```bash
cd ansible && ansible-playbook site.yml --limit vps
```

## Gated step: `restic init`

The local repository was initialised on 2026-09-28. Do not initialise it again. `restic init` refuses
a non-empty repository. That refusal is the expected result on a host that already has data.

On a new host, confirm the repository path is empty before `restic init`. Run the command only after
an explicit check:

```bash
ssh vps "install -d -m 700 /var/backups/restic"
ssh vps 'set -a; . /etc/vps-backup/env; set +a; \
  RESTIC_REPOSITORY=/var/backups/restic restic init'
```

The R2 repository was initialised in the same way on 2026-09-29.

## Enable the timers

All eight are enabled on the current host. To enable them on a rebuilt host:

```bash
ssh vps 'systemctl enable --now \
  vps-backup-classA.timer vps-backup-classC.timer \
  vps-etcd-snapshot.timer vps-backup-offsite.timer \
  vps-backup-prune.timer vps-restic-check.timer \
  vps-restore-test.timer vps-restore-test-c.timer'
```

Do not omit `vps-backup-prune.timer`. Without it the local repository grows without bound.

## Offsite credentials

The R2 endpoint and S3 key pair are host-local in `/etc/vps-backup/r2.env`, mode 0600. They are not
in git and not in SOPS. The unit loads the file with `EnvironmentFile=`. The key is scoped to the
`vps-backups` bucket with Object Read & Write. Do not use the Terraform state token.

The script is a no-op when `RESTIC_REPOSITORY` is absent. On the current host the file exists and the
hourly copy runs. The script sets `RESTIC_FROM_REPOSITORY` and `RESTIC_FROM_PASSWORD` from the local
repository. It writes its metric only after a successful copy. Missing data therefore raises the
`vps-backup-offsite-stale` alert, which is correct for a host with no offsite copy.

`RESTIC_OFFSITE_PASSWORD` in `r2.env` is optional. If set, the R2 repository must have that key. The
default is the local repository password. A password rotation on the local repository must also be
applied to R2 or the copy stops.

The offsite repository is never pruned. Retention runs on the local repository only. R2 bucket-lock
rules are intended to make deletion impossible. The offsite repository grows monotonically.

## Restore drill behavior

`vps-restore-test.sh [A|C]` defaults to class A. Each run:

1. Restores the newest `class-<X>` snapshot into a scratch directory.
2. Checks each `postgres` dump for the `PGDMP` magic, lists it with `pg_restore --list`, imports it
   into a scratch database, and compares its table list and row counts with the live database.
   Class A has one such target. Class C has none, so its import loop does nothing.
3. Checks each `mongo` archive by restoring it into a scratch `mongo` instance and comparing
   collections and document counts. The registry has no `mongo` target today, so this loop does
   nothing.
4. For each `file` target, validates raw database trees where present. It treats a directory that
   holds `PG_VERSION` as a cluster root only when a sibling `global/` directory exists. The
   `PG_VERSION` file must record version 16. The `global/pg_control` file must not be empty. At
   least one entry must exist under `base/`. A nested `base/<oid>/PG_VERSION` file is not a cluster
   root and does not fail the check. It treats a `WiredTiger` file as a Mongo tree when the file is
   not empty and a sibling `journal/` directory exists.
5. Requires every registered `file` target path to exist in the restored snapshot. A missing path is
   a failure, not a skip.
6. Diffs the restored file list against the live directories for each `file` target.
7. Removes its scratch namespace and writes the per-class metric
   `vps_restore_test_last_success_timestamp{class="A"|"C"}` only on success.

The drill reports any target with an engine it cannot check as `NOT COVERED` and increments
`vps_restore_test_uncovered_targets{class=…}`. It does not count that target as verified.

The class label is load-bearing. Without it a class-C run would satisfy the class-A staleness alert.
The pre-DR-004 unlabelled metric file is removed on a class-A run only.

The Mongo check does not replay an archive oplog. It tests the dumped data against a standalone
scratch instance. The production instance was a replica-set member. Replaying oplog entries on a
standalone instance would test a path production never uses.

## Known gaps

- R2 bucket-lock tolerance is unvalidated. The offsite repository is never pruned, so the question is
  whether a future `restic forget --prune` could run against locked objects. It remains open.
- `meghmitra-data-pvc` has no host path. It has no recoverable content and no backup target. See
  [`docs/storage.md`](../../../docs/storage.md).
- Prometheus and Loki are not backed up. They are disposable monitoring data.
- Healthchecks.io dead-man URLs were declined by the owner on 2026-09-28. Alerting uses the
  node-exporter textfile metrics plus `systemctl` and journal output.
- The offsite repository only grows. This is deliberate until bucket-lock behavior is tested.

## Historical validation

Measurements below are historical. They describe the retired logical-dump layout, not the current
raw file targets.

- **2026-09-28, check then apply:** `ok=21 changed=12 failed=0`. Before the run, two vcap paths
  pointed at a missing directory, the Grafana SQLite pre-copy was claimed but absent, and
  `RESTIC_REPOSITORY` was assigned but not exported.
- **2026-09-28, restore test:** `restic restore latest` produced 187 files and 20.4 MiB. The
  meghmitra dump listed 100 TOC entries with the real schema.
- **2026-09-28, drill import:** class-A dumps imported into scratch databases and matched table
  counts (vcap-staging 57, meghmitra 17).
- **2026-09-28, first full run:** check, drill, and etcd push exited 0. `restic check` verified 5
  snapshots and read 10% of pack data. The etcd push stored 45.4 MiB, 6.2 MiB on disk.
- **2026-09-28, drill bug:** the first drill called `kubectl exec "$ns/$name"` without `-n`. Every
  exec failed with stderr suppressed. The fix is `kubectl exec -n "$ns" "$name"`. Do not reintroduce
  the silent-stderr pattern.
- **2026-09-29, offsite:** the R2 copy was enabled. The first copy completed. Since then the hourly
  timer has copied every tag.

The current drills were rewritten on 2026-10-23 for raw static data and the then-live `vcap-v1` Postgres
target. That target was retired on 2026-10-27. They are deployed with this role revision. Their next scheduled runs are 2026-11-01 (class A)
and 2026-11-15 (class C).
