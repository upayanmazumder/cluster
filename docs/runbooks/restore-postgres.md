# Runbook: restore a Postgres database

Two cases exist after the 2026-10-23 retirement:

- **Live `vcap-v1`.** `vcap-backend-v1-postgres` still runs. Its class-A backup is a logical
  `pg_dump` plus globals. Use the dump and the in-place variant.
- **Retired data.** `vcap-staging`, `vcap-dev`, `meghmitra`, and `bitvault` have no Postgres
  workload. Their namespaces, Secrets, and PVCs remain. The data is static and class A or class C
  holds a raw copy of it. Recover it with a temporary `postgres:16` pod that mounts a **copy** of
  the tree.

> **Do not start Postgres on the retained data directory.** Start it on a copy. A start can run
> crash recovery and write WAL. The retained tree may be the only live copy. A temporary pod must
> not create a Service, an IngressRouteTCP, or a firewall rule.

## Current backup content

Class A runs every 30 minutes:

- `vcap-v1/vcap-backend-v1-postgres`: `pg_dump -Fc` plus `pg_dumpall --globals-only`, written to
  `var/backups/staging/class-A/pg/` inside the snapshot.
- `vcap-staging/vcap-backend-staging-data`: raw `/srv/data/vcap-staging` tree.
- `vcap-v1/vcap-backend-v1-data`: raw application-data PVC.

Class C runs daily:

- Raw `/srv/data/vcap-dev`, `/srv/data/adhigrahan-radar-data`, `/srv/data/meghmitra-postgres`,
  the bitvault Postgres and MinIO PVCs, the rankstack Mongo PVC, and the Grafana host path.

Class A no longer contains the old `vcap-staging` or `meghmitra` Postgres dumps. Those workloads
were retired. Their PVC data is raw and static.

## Getting a snapshot out of the repository

Run these commands on the node as root. The repository is root-owned and mode 0700.

```bash
set -a; . /etc/vps-backup/env; set +a          # RESTIC_PASSWORD, mode 0600
export RESTIC_REPOSITORY=/var/backups/restic

restic snapshots --tag class-A                  # or class-C
restic restore latest --tag class-A --target /var/tmp/recover-a
```

A class-A restore contains:

```text
/var/tmp/recover-a/var/backups/staging/class-A/pg/vcap-v1-vcap-backend-v1-postgres.dump
/var/tmp/recover-a/var/backups/staging/class-A/pg/vcap-v1-vcap-backend-v1-postgres-globals.sql
/var/tmp/recover-a/srv/data/vcap-staging/postgres/pgdata/
/var/tmp/recover-a/var/lib/rancher/k3s/storage/pvc-d4b91391-4691-43c4-9590-6bbe1ddf0ad9_vcap-v1_vcap-backend-v1-data/
```

A class-C restore contains the raw tree for each target. The bitvault Postgres tree is at:

```text
/var/tmp/recover-c/var/lib/rancher/k3s/storage/pvc-4f59ae33-a946-42a4-bb05-0c0bd458e454_bitvault_bitvault-postgres-pvc/pgdata/
```

The vcap-dev tree is at `/var/tmp/recover-c/srv/data/vcap-dev/postgres/pgdata/`. The meghmitra tree
is at `/var/tmp/recover-c/srv/data/meghmitra-postgres/`.

If the node is gone, the R2 copy is the fallback. The restic password is in
`ansible/group_vars/vps/secrets.sops.yaml` (key `restic_password`). The password is also in the
owner's password manager. Without it, every snapshot is unreadable.

## Variant A: live vcap-v1 logical restore

This overwrites live data. Take a fresh dump of the current state first if it may still have value.
Confirm the target with the owner.

```bash
NS=vcap-v1
DEPLOY=vcap-backend-v1-postgres
POD=$(kubectl -n "$NS" get pods -o name | grep "$DEPLOY" | head -1 | cut -d/ -f2)

kubectl cp /var/tmp/recover-a/var/backups/staging/class-A/pg/vcap-v1-vcap-backend-v1-postgres.dump \
  "$NS"/"$POD":/tmp/restore.dump

kubectl exec -n "$NS" "$POD" -- sh -c '
  set -e
  PGPASSWORD="$POSTGRES_PASSWORD" dropdb -U "$POSTGRES_USER" "$POSTGRES_DB"
  PGPASSWORD="$POSTGRES_PASSWORD" createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"
  PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/restore.dump
  rm -f /tmp/restore.dump
'

kubectl rollout restart deploy/vcap-backend-v1-postgres -n "$NS"
kubectl rollout status deploy/vcap-backend-v1-postgres -n "$NS"
```

The postgres Pod holds `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` from Secret
`backend-env`. Run the restore inside the pod, so the credentials do not reach shell history.

Apply `globals.sql` separately if roles are missing. It is a plain `pg_dumpall --globals-only`
script, not part of the `.dump` file.

Validate that the expected tables exist. Check row counts against the time of the dump. Confirm the
`vcap-backend-v1-api` and `vcap-backend-v1-worker` pods reconnect and pass health checks.

## Variant B: retired static data

The drill does this automatically for `file` targets. The steps below are the manual equivalent.

### 1. Make a writable copy

Use the restored snapshot, not the live PVC. This example restores `vcap-staging`.

```bash
SRC=/var/tmp/recover-a/srv/data/vcap-staging/postgres/pgdata
DST=/var/tmp/pg-recover
install -d -m 700 "$DST"
cp -a "$SRC"/. "$DST"/
chown -R 999:999 "$DST"
```

Version 16 is required. Check it before you start anything:

```bash
cat "$DST/PG_VERSION"
```

If `postmaster.pid` exists, remove it only after you confirm no server is running against this
copy. A stale PID file can stop the server.

### 2. Start a temporary pod on the copy

Create the pod in the source namespace so it can read the retained Secret. The pod has no Service
and no Ingress.

```bash
NS=vcap-staging
```

Create `pg-recover` with a `hostPath` volume for `/var/tmp/pg-recover` and `PGDATA` set to
`/scratch/pgdata`. Use image `postgres:16`. Do not run `initdb`. The data directory already exists.

```bash
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pg-recover
spec:
  restartPolicy: Never
  containers:
    - name: postgres
      image: postgres:16
      env:
        - name: PGDATA
          value: /scratch/pgdata
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef: {name: backend-env, key: POSTGRES_DB}
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef: {name: backend-env, key: POSTGRES_USER}
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef: {name: backend-env, key: POSTGRES_PASSWORD}
      volumeMounts:
        - {name: data, mountPath: /scratch}
      resources:
        requests: {memory: 256Mi}
        limits: {memory: 1Gi}
  volumes:
    - name: data
      hostPath: {path: /var/tmp/pg-recover, type: Directory}
EOF
```

The pod reads `POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` from `secretKeyRef` in
`backend-env`. It does not print them. Keep the container as the only container in the pod.

Wait for the final server over TCP, not the unix socket. The entrypoint starts a temporary server
during init. A unix-socket check can pass against that server and then fail when it shuts down.

```bash
until kubectl -n "$NS" exec pg-recover -- pg_isready -h 127.0.0.1 >/dev/null 2>&1; do
  sleep 3
done
```

If you cannot use `secretKeyRef`, read the keys without echoing them:

```bash
kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.POSTGRES_USER}' | base64 -d
```

Put the value into the pod manifest or an environment variable. Do not paste it into chat or a
ticket.

### 3. Dump or inspect

```bash
kubectl -n "$NS" exec pg-recover -- sh -c '
  pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > /tmp/recovered.dump
  pg_restore --list /tmp/recovered.dump | head
'
kubectl cp "$NS"/pg-recover:/tmp/recovered.dump /var/tmp/recovered.dump
```

Use the dumped file for a later import. Do not point the live app at this temporary pod.

### 4. Clean up

```bash
kubectl -n "$NS" delete pod pg-recover
rm -rf /var/tmp/pg-recover /var/tmp/recover-a
```

Delete the temporary pod before you leave. Do not delete the PVC, the PV, or the Secret.

## Variant C: verify a backup without touching production

The restore drill is the executable reference. It restores the newest snapshot for class A or
class C, imports the `vcap-v1` dump into a scratch database, compares table lists and row counts
with live, checks raw Postgres trees, and removes its scratch namespaces.

```bash
ssh vps '/usr/local/sbin/vps-restore-test.sh A'
ssh vps '/usr/local/sbin/vps-restore-test.sh C'
```

The drill uses the `restore-test` namespace for class A and `restore-test-c` for class C. It holds
`/var/lock/vps-restore-test.lock` so the two runs cannot overlap.

## Status

The class-A import and raw-tree checks run on the 1st at 05:00 UTC. The class-C run is on the 15th
at 06:00 UTC. Historical measurements from 2026-09-28 (vcap-staging 57 tables, meghmitra 17 tables)
applied to the old logical-dump layout and no longer describe the current registry.
