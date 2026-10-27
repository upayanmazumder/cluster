# Runbook: restore a Postgres database

Two cases exist after the 2026-10-23 retirement:

- **Retired `vcap-v1`.** No Postgres workload runs since 2026-10-27. A final dump and a raw tree
  remain in class C. See Variant A.
- **Retired data.** `vcap-staging`, `vcap-dev`, `meghmitra`, and `bitvault` have no Postgres
  workload. Their namespaces, Secrets, and PVCs remain. The data is static and class A or class C
  holds a raw copy of it. Recover it with a temporary `postgres:16` pod that mounts a **copy** of
  the tree.

> **Do not start Postgres on the retained data directory.** Start it on a copy. A start can run
> crash recovery and write WAL. The retained tree may be the only live copy. A temporary pod must
> not create a Service, an IngressRouteTCP, or a firewall rule.

## Current backup content

Class A runs every 30 minutes:

- `vcap-staging/vcap-backend-staging-data`: raw `/srv/data/vcap-staging` tree.
- `gitorgasm` Postgres: logical dump, written to `var/backups/staging/class-A/pg/` in the snapshot.

Class C runs daily:

- Raw `/srv/data/vcap-dev`, `/srv/data/adhigrahan-radar-data`, `/srv/data/meghmitra-postgres`,
  the bitvault Postgres and MinIO PVCs, the rankstack Mongo PVC, and the Grafana host path.
- `vcap-v1` (retired 2026-10-27): raw `/srv/data/vcap-v1-postgres`, the raw app-data PVC path, and
  `/srv/data/vcap-v1-final-dump`.

Class A holds no `vcap-v1` data. Class A no longer holds the old `vcap-staging` or `meghmitra`
Postgres dumps. Those workloads were retired. Their PVC data is raw and static.

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
/var/tmp/recover-a/srv/data/vcap-staging/postgres/pgdata/
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

## Variant A: vcap v1 data (retired 2026-10-27)

The `vcap-v1` workloads were retired on 2026-10-27. No Postgres server runs in namespace `vcap-v1`.
No Service, route, or public port exists. Only retained data remains. Use one of two methods.

Retained items in `vcap-v1`:

- Final dump: `/srv/data/vcap-v1-final-dump/vcap-v1-pg_dumpall-20261027.sql.gz` (class C).
- Raw Postgres 16 tree: `/srv/data/vcap-v1-postgres/pgdata/` (PV `vcap-v1-postgres-data-vps`, Retain).
- Application data: PV `pvc-d4b91391-4691-43c4-9590-6bbe1ddf0ad9` (Retain).

### Method 1: restore the final dump

The dump is a `pg_dumpall` script. It has the roles and all databases. Restore it into a temporary
Postgres 16 pod. Do not restore it into a retained data directory.

```bash
NS=vcap-v1
kubectl -n "$NS" run pg-recover --image=postgres:16 --restart=Never \
  --env=POSTGRES_PASSWORD=recover-only
kubectl -n "$NS" wait --for=condition=Ready pod/pg-recover --timeout=120s
until kubectl -n "$NS" exec pg-recover -- pg_isready -U postgres >/dev/null 2>&1; do sleep 3; done

zcat /srv/data/vcap-v1-final-dump/vcap-v1-pg_dumpall-20261027.sql.gz \
  | kubectl -n "$NS" exec -i pg-recover -- psql -U postgres -q -o /dev/null
kubectl -n "$NS" exec pg-recover -- psql -U postgres -d latex_capstone -Atc \
  "select count(*) from pg_tables where schemaname='public'"
```

Use the restored files from `/var/tmp/recover-c/srv/data/vcap-v1-final-dump/` if the node is new.
The last line of the dump reads `cluster dump complete`. Expect 58 tables and 104 live rows in the
database `latex_capstone`. Messages that a role or database "does not exist, skipping" are normal.
Delete the pod when you finish with `kubectl -n vcap-v1 delete pod pg-recover`.
Do not create a Service, an IngressRouteTCP, or a firewall rule.

### Method 2: start Postgres on a COPY of the raw tree

Never start Postgres on `/srv/data/vcap-v1-postgres`. Copy it first. Follow Variant B steps 1 to 4
with these values:

```bash
SRC=/srv/data/vcap-v1-postgres/pgdata      # or /var/tmp/recover-c/srv/data/vcap-v1-postgres/pgdata
NS=vcap-v1
```

Use Secret `backend-env` in `vcap-v1` for the credentials. The data is Postgres 16.

### Clean up

```bash
kubectl -n vcap-v1 delete pod pg-recover
rm -rf /var/tmp/pg-recover
```

Do not delete the PVCs, the PVs, or the Secrets in `vcap-v1`.

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
class C. It imports each logical dump into a scratch database and checks the raw Postgres trees.
It removes its scratch namespaces when it ends.

```bash
ssh vps '/usr/local/sbin/vps-restore-test.sh A'
ssh vps '/usr/local/sbin/vps-restore-test.sh C'
```

The drill uses the `restore-test` namespace for class A and `restore-test-c` for class C. It holds
`/var/lock/vps-restore-test.lock` so the two runs cannot overlap.

## Status

The class-A and class-C drills run on a schedule. Class A runs on the 1st at 05:00 UTC. Class C runs
on the 15th at 06:00 UTC. Measurements from 2026-09-28 (vcap-staging 57 tables, meghmitra 17
tables) are historical. They do not describe the current registry.
