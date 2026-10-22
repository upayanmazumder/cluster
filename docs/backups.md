# Backups

Full detail: the architecture review (private, not published) §12.

## Offsite target: Cloudflare R2 (live since 2026-09-29)

Bucket `vps-backups` exists in the same Cloudflare account as the DNS zone: region **WEUR**, storage
class Standard, created 2026-09-27. It is **in use**: the hourly `vps-backup-offsite.timer` runs
`restic copy` of every tag from the node-local repository into it, and it holds the full offsite set
(class A, class C, `etcd`, image tarballs). Verified 2026-09-29: `restic snapshots` against the R2
repository lists the latest snapshots, including a class-A copy from the same afternoon.

`vps-tfstate` likewise exists and — owned by `cluster/terraform` — now backs the terraform
**`s3` backend** (`backend = "s3"`, bucket `vps-tfstate`, key `vps/terraform.tfstate`,
`use_lockfile = true`, switched 2026-09-29 / TF-001). The `vps` repository no longer holds Terraform
configuration (P3-04/P3-06); the state is no longer a gitignored local file.

Reachability was proven from the node before the keys existed: `curl` against
`https://<account-id>.r2.cloudflarestorage.com/vps-backups` gets a TLS-valid response from R2's S3
API. The credentials are host-local, never committed — see the role README for the file.

**Feasibility measured 2026-09-28:** the node itself reaches Cloudflare at **101 MB/s** (25 MB in
0.25 s), so a full copy of the repository is seconds of transfer.

**Cost.** R2's free tier is 10 GB-month of storage, 1M Class A operations, 10M Class B operations,
and unlimited free egress (permanent, not a trial). The repository is bounded by the retention
policy rather than growing without limit. **Class A operations are the metric with the least
headroom**: restic lists the repository on every run, and the class-A timer's cadence is what
multiplies that. At `OnUnitActiveSec=30min` the expected count is roughly half the 15-minute cadence.

**Credentials are created in the dashboard, not the API.** `POST …/r2/api_tokens` and `…/r2/tokens`
both return `10015 No route matches this url`; the only credential route that exists is
`…/r2/temp-access-credentials`, which issues short-lived credentials unusable as a repository
credential. Long-lived keys come from **Dashboard → R2 → Manage R2 API Tokens → Create API Token**,
scoped to `vps-backups` with Object Read & Write.


## Current state (2026-09-29): automated, locally-restic'd, offsite to R2, monitored

Backups are **live** as of 2026-09-28 (S3/S4, Ansible-managed from `ansible/roles/backup`), with the
**R2 offsite leg enabled 2026-09-29** (DR-001). Eight systemd timers run on the node: class A every
30 min, class C daily, etcd snapshots every 12h, the hourly offsite `restic copy` to R2, a weekly
`restic forget --prune`, a weekly `restic check`, and two monthly restore drills (class A on the 1st,
class C on the 15th). Targets come from
[`../ansible/files/backup-targets.yaml`](../ansible/files/backup-targets.yaml) (every path in it is
verified against the live host — a wrong path fails *quietly*, which is why that registry carries a
re-verify note). For each target, the script does one of three things: a logical dump for `postgres`,
an archive for `mongo`, or no copy step for `file` (restic reads that path directly).

On 2026-10-23 the vcap v2, bitvault, rankstack, kirro, bandit, and upayan-v5 workloads were retired.
Their namespaces and PVCs remain. The Postgres and Mongo engines no longer run, so their data is
backed up as raw, static files. Read [runbooks/restore-postgres.md](runbooks/restore-postgres.md) or
[runbooks/restore-mongo.md](runbooks/restore-mongo.md) before you recover them.

- **Repository: `/var/backups/restic` on the root disk, with an hourly offsite copy in R2.** The
  local repository is deliberately a *different device* from `/srv/data`, so it survives a
  `vps-data` problem and covers accidental deletion, a bad migration and logical corruption; the
  hourly `restic copy` into Cloudflare R2 (`vps-backups`) is what covers losing the host. The
  source `backup_restic_repository` stays `/var/backups/restic`; the offsite destination comes from
  the host-local `r2.env`.
- **Restic password:** generated 2026-09-28, stored SOPS-encrypted at
  `ansible/group_vars/vps/secrets.sops.yaml`, and rendered to `/etc/vps-backup/env` (mode 0600) by a
  `no_log` task. **Losing it makes every snapshot unreadable** — it belongs in the owner's password
  manager next to the age keys.
- **Verified restorable (measured 2026-09-28, historical):** `restic restore latest` reproduced 187
  files / 20.4 MiB including the MinIO object tree, and the meghmitra `pg_dump` was validated inside
  the live postgres pod with `pg_restore --list` → **100 TOC entries** with the real schema. The
  meghmitra and vcap v2 workloads are now retired. Their data is static and is validated as raw
  files by the current drill.
- **Monitored:** the scripts write into node_exporter's textfile collector (wired 2026-09-28). Five
  timestamp metric families are scraped. They produce six series because class A and class C share
  one family: `vps_backup_last_success_timestamp{class="A"|"C"}`,
  `vps_etcd_snapshot_last_success_timestamp`, `vps_restic_check_last_success_timestamp`,
  `vps_restore_test_last_success_timestamp{class="A"|"C"}`,
  `vps_backup_offsite_last_success_timestamp`, plus the count metric
  `vps_restore_test_restored_files`. Six Grafana rules alert on staleness — class A > 45 min, class C
  > 26 h, etcd > 36 h, restic check > 10 d, restore drill > 40 d, offsite > 4 h — and all of them
  fire on *no data* as well, because for backups silence means failure.
- **Verified weekly (Sundays 04:00 UTC):** `restic check` plus `--read-data-subset=10%`. A backup tool
  that only ever writes will happily store corruption; this is what reads it back. First run: 5
  snapshots checked, 10% of pack data read, no errors.
- **Verified monthly (1st, 05:00 UTC) — automated restore drill.** Restores the newest snapshot for
  the requested class into a scratch directory and then *validates the artefacts*. The drill now runs
  for both class A and class C.
  - A snapshot that contains logical dumps gets the strict path: every `*.dump` must start with the
    `PGDMP` magic, be listed by `pg_restore --list`, and import into a scratch database. Class A
    now has one dump target, `vcap-v1/vcap-backend-v1-postgres`, so the loop imports that dump and
    compares its table list and row counts with the live database. Class C has no dump target, so
    its loop no-ops.
  - Raw `file` targets are checked directly. The drill finds `PG_VERSION` and requires version 16. It
    requires a non-empty `global/pg_control` and at least one entry under `base/`. It finds
    `WiredTiger` and requires the sibling `journal/` directory.
  - Every restored file must still exist in the live directory. For `/srv/data/vcap-staging`, this
    covers the Postgres data tree, MinIO, artifacts, and the workspace.
  - If the drill cannot run a check it **fails**, writes no metric, and removes its scratch
    namespaces. The class-A metric is separate from the class-C metric, so one class cannot mask the
    other.
  - **Current result (2026-10-23):** class A restored snapshot `bc2ea61d` in 60.68 s. It imported
    the `vcap-v1` dump with 416 TOC entries and 58 tables. Its 104 live rows matched 104 restored
    rows. Class C restored snapshot `a88c92f5` in 17.05 s and matched all 9 targets. Both runs
    reported success and wrote their metrics. These times cover data restore and validation only.
  - **Historical first run (2026-09-28, before retirement):** 139 files and directories restored,
    dumps listed 100 and 409 TOC entries, and imports matched the live database (vcap-staging 57
    tables, meghmitra 17). That measurement applied to the retired logical-dump layout.
- **Unrepullable images are backed up.** `/var/backups/images/*.tar` — exported with `k3s ctr images
  export <out.tar> <repo>@sha256:…` from *workload templates* (not running pods, or KEDA
  scale-to-zero workloads are missed) — is carried by the 12h infrastructure job. It holds the S0
  MinIO tarball plus every private image that could be exported at that time: vcap's `api`, `auth`
  and frontend `web`. Verified 2026-09-28: the run reports 4 tarballs, the snapshot lists them, 218
  MiB stored. These tarballs are historical. The vcap v2, bitvault, and rankstack workloads were
  retired on 2026-10-23.
  - **Historical, 2026-09-28:** `vcap-staging-backend/worker`'s image was **not in the node cache**
    and could not be pulled, so a KEDA scale-up would fail. `bitvaultd`'s manifest was cached but its
    blobs were GC-pruned. Both Deployments are now deleted, so this failure mode is gone.
  - **Historical, resolved 2026-09-28.** The owner refreshed the `gh` token with `write:packages` and
    copied it into the pull Secrets. Consequences at that time:
    - `vcap-staging-backend/worker`'s image was pulled onto the node.
    - `bitvaultd` pulled successfully. It was not exportable because a layer blob was absent.
    - `argocd-image-updater` reported **`errors=0`** and tracked 23 images. See
      [upgrade-policy.md](upgrade-policy.md) for the current list.
    - `quay.io/minio/minio:RELEASE.2025-04-22` was pushed to
      `ghcr.io/upayanmazumder/mirror/minio`. The three MinIO Deployments ran from it until they were
      retired on 2026-10-23. The mirror image remains published. No current workload in `vcap-dev`,
      `vcap-staging`, or `bitvault` uses it.
- **etcd is offsite now too.** `vps-etcd-snapshot.sh` pushes the snapshot *plus the k3s server token
  and TLS material* — the things an etcd restore actually needs, and previously not captured anywhere
  — tagged `etcd`, retained 14 recent + 12 monthly. First run: 45.4 MiB (6.2 MiB stored).
- **Grafana's sqlite gets a consistent copy.** The registry declared a `sqlite3 .backup` pre-step
  from the day it was written, but the script never did it — restic was reading a database Grafana
  may be mid-write on. Implemented 2026-09-28; a missing `sqlite3` is now a hard failure rather than
  a warning.
- **Open item:** R2 bucket-lock tolerance validation. The offsite repository is never pruned, so it
  only grows. Whether a future `restic forget --prune` could run against locked objects is not
  tested. Dead-man URLs were declined by the owner. Staleness alerting uses the Prometheus textfile
  metrics and `systemctl`/journal status instead. The rankstack Mongo database was empty on
  2026-09-28 (0 documents), so its historical dump was small. The workload is retired now. Its PVC
  is backed up as raw static files.
- **The S0 one-off snapshot still exists** (`/root/pre-migration-2026-09/` on the node plus the
  operator workstation copy) as an independent point-in-time record; it is now no longer the only
  backup material.

## Workstation mirror — the copy outside both providers (DR-003, 2026-09-28)

Every other copy of this data lives with the same two providers: the node's restic repository is on
Hetzner, and the offsite leg is R2 (Cloudflare). The worst case in the DR table is "both
Hetzner and Cloudflare compromised", and for that the only surviving copy has to live somewhere else.

`scripts/pull-backups.sh` copies the repository to a workstation mirror using `restic copy`, so it is
incremental after the first run and needs the same password on both sides — read from SOPS at run time,
never stored beside the mirror. It copies **all** tags (class A, class C, etcd, image tarballs) because
a class-A-only mirror omits most of what a rebuild actually needs; `VPS_BACKUP_TAGS=class-A` restricts it
deliberately.

**Size and cost, measured 2026-09-28.** The node's repository is **383 MB** — the whole repository, not
one class — so the mirror is the same order. That matters because this workstation's `/home` runs close
to full; the mirror is small enough that it is not a reason to defer, and it only grows by the deltas the
node produces. The first copy takes roughly **20 minutes**, because the *path* is the limit rather than
restic. Measured 2026-09-28: this workstation pulls from the node at ~299 kB/s (100 MB in 180 s) but
reaches Cloudflare at ~1.7 MB/s (25 MB in 14.5 s), so the constraint is the workstation↔node path in
particular, not the workstation's own capacity — worth knowing before concluding "the mirror is slow".
Later runs copy only new packs: the next one took **25 seconds**. That asymmetry is the argument for the
timer below rather than a terminal, and it is why a nightly cadence is cheap even though the first copy
is not.

**Scheduling it.** A systemd *user* timer, because the run needs the operator's age key and `restic` from
`PATH` — a user unit is the right scope, and `Persistent=true` means a run missed while the machine is
off happens at the next login:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/vps-backup-mirror.service <<'EOF'
[Unit]
Description=Mirror the vps restic repository to this workstation

[Service]
Type=oneshot
# A timer has no terminal: without this the first run waits for the `restic init` confirmation and the
# unit appears to hang. `sops` finds the age key in its default location, so no path is configured here.
Environment=VPS_BACKUP_ASSUME_YES=1
ExecStart=%h/dev/upayanmazumder/cluster/scripts/pull-backups.sh
EOF
cat > ~/.config/systemd/user/vps-backup-mirror.timer <<'EOF'
[Unit]
Description=Daily mirror of the vps restic repository

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now vps-backup-mirror.timer
systemctl --user list-timers vps-backup-mirror.timer
```

Two things to know about that unit: `ExecStart` points at **this private repository's** checkout, so
after the cutover (PUB-005) it must point at the public clone — the script itself is identical; and the
mirror is a second restic repository with its own key, so if the node's repository password is ever
rotated the mirror needs the new one too (`restic key add` on the mirror), or the script stops working.

## Backup architecture (S4 — live)

Host-level `vps-backup` (Ansible-managed script + systemd timers): **every 30 min for class A**
datasets, daily for class C, 12-hourly for etcd.

1. Per entry in `ansible/files/backup-targets.yaml` (git-tracked registry: namespace, workload,
   engine, class, path):
   - Postgres: `pg_dump -Fc` (+ `pg_dumpall --globals-only`) → the class staging directory. The
     registry has one Postgres target: `vcap-v1/vcap-backend-v1-postgres`. It is live, so a logical
     dump is consistent where a raw file copy is not.
   - Mongo: `mongodump --archive --gzip` → the class staging directory. The registry has no Mongo
     target today. The rankstack workload is retired and its PVC is backed up as raw files.
   - `file`: restic reads the exact `path` directly. Current targets are `/srv/data/vcap-staging`,
     `/srv/data/vcap-dev`, `/srv/data/adhigrahan-radar-data`,
     `/srv/data/meghmitra-postgres`, the vcap-v1 app-data PVC, the bitvault PVCs, the rankstack
     Mongo PVC, the Grafana host path, and both kirro PVCs (`kirro-mock-data` and
     `kirro-voice-logs`).
   - Grafana and Adhigrahan: `sqlite3 .backup` copy, then the file path.
2. Every 12h: `k3s etcd-snapshot save` + copy of `/var/lib/rancher/k3s/server/{token,tls/}` and
   `/etc/rancher/k3s/`.
3. `restic backup "$STAGING_DIR" $FILE_PATHS` with the SQLite exclusions → local repository, then
   the hourly `restic copy` → Cloudflare R2 bucket `vps-backups` (restic repo password in Ansible
   SOPS vars + owner password manager).
4. Retention: class A `--keep-within 48h --keep-daily 30 --keep-weekly 12 --keep-monthly 12`; class
   C `--keep-daily 7` (separate restic tags); `prune` weekly.
5. Integrity: `restic check --read-data-subset=10%` every Sunday at 04:00 UTC.
6. Failure detection: script exit status, journal output, and a
   `vps_backup_last_success_timestamp{class="A|C"}` textfile metric → Prometheus alerts if class A
   is > 45 min stale or class C > 26 h stale. No external dead-man service is used.
7. Credential-compromise protection: R2 bucket-lock rule (e.g. 14 days) on the restic prefix; the
   VM's R2 token is scoped to that bucket only. Offsite retention is disabled, so `prune` does not run
   against R2 today. Whether restic's `prune` tolerates locked-object delete failures remains
   unvalidated — if it cannot, drop the lock rule and add a weekly pull-copy to the owner's
   workstation instead.
8. Restore drills: monthly automated `vps-restore-test` runs for class A and class C. It restores the
   latest snapshot of the requested class, validates raw Postgres and Mongo trees, diffs the
   restored file list against the live paths, and removes its scratch namespaces. The import loop
   runs for registry targets with `engine: postgres` or `engine: mongo`. Class A has one `postgres`
   target, `vcap-v1/vcap-backend-v1-postgres`, so the drill imports that dump and compares it with
   the live database. Class C has no dump or archive target, so its import loop does nothing. See
   [`ansible/roles/backup/templates/vps-restore-test.sh.j2`](../ansible/roles/backup/templates/vps-restore-test.sh.j2).
   Quarterly manual full DR drill on a temporary VM — see the architecture review (private, not
   published) §17 S12.
9. Optional (costs nothing): weekly `restic copy`/pull of class A snapshots to the owner's
   workstation — the only copy that survives a simultaneous Cloudflare **and** Hetzner compromise.

**Hetzner's own automated server backups are deliberately NOT enabled** — owner decision
2026-09-28, the ~20% server-plan surcharge is over budget. This means there is no whole-VM
rollback for a bad OS/k3s upgrade beyond `k3s etcd-snapshot` + Ansible-driven rebuild (see
[`disaster-recovery.md`](disaster-recovery.md)) — restic → R2 remains the real, budgeted backup
path for actual data and is unaffected by this decision.

## Related

- [`storage.md`](storage.md) — per-dataset table this backup policy is keyed off
- [`disaster-recovery.md`](disaster-recovery.md) — RPO/RTO targets per loss scenario
- [`runbooks/restore-postgres.md`](runbooks/restore-postgres.md), [`runbooks/restore-mongo.md`](runbooks/restore-mongo.md), [`runbooks/restore-minio.md`](runbooks/restore-minio.md), [`runbooks/recover-k3s.md`](runbooks/recover-k3s.md), [`runbooks/recover-vm.md`](runbooks/recover-vm.md)
