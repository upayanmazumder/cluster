# Runbook: restore rankstack's Mongo data

> **Retired workload (2026-10-23).** The `rankstack` Deployment, Services, Ingress, and replica-set
> Job no longer exist. The namespace, Secret, and `rankstack-mongo-pvc` remain. The PVC holds a
> static WiredTiger tree. `kubectl scale deploy/rankstack-mongo` does not work. Recover the data
> with a temporary `mongod` pod that mounts a **copy** of the tree. Do not start `mongod` on the
> retained PVC. Do not recreate the old Deployment or route unless you intend to serve the app
> again.

## What is backed up now

Class C runs daily and includes the raw PVC:

```text
rankstack/rankstack-mongo
  /var/lib/rancher/k3s/storage/pvc-fb2fad5e-3e23-46cb-af88-659ecee047f6_rankstack_rankstack-mongo-pvc
```

The registry uses `engine: file`, so restic reads the tree directly. There is no `mongodump` target
in the current registry. A snapshot may still contain old archives under
`var/backups/staging/class-C/mongo/rankstack-rankstack-mongo.archive.gz`. Those archives are
historical. Use the raw WiredTiger tree for current recovery.

Measured 2026-10-23: the PVC holds 509 MB. The tree contains `WiredTiger` and `journal/`. The
2026-09-28 measurement of 369 MB allocated with 0 documents and 5 collections described the old
running database. It does not describe the current raw tree.

## Restore the snapshot

Run these commands on the node as root.

```bash
set -a; . /etc/vps-backup/env; set +a
export RESTIC_REPOSITORY=/var/backups/restic

restic snapshots --tag class-C
restic restore latest --tag class-C --target /var/tmp/recover-c
```

The tree is at:

```text
/var/tmp/recover-c/var/lib/rancher/k3s/storage/pvc-fb2fad5e-3e23-46cb-af88-659ecee047f6_rankstack_rankstack-mongo-pvc
```

Restic password: `ansible/group_vars/vps/secrets.sops.yaml`, key `restic_password`. The owner's
password manager also holds it. Without it, the snapshot is unreadable.

## Start mongod on a copy

Copy the tree. Mongo writes to the data directory during startup and recovery. Never point it at
the retained PVC.

```bash
SRC=/var/tmp/recover-c/var/lib/rancher/k3s/storage/pvc-fb2fad5e-3e23-46cb-af88-659ecee047f6_rankstack_rankstack-mongo-pvc
DST=/var/tmp/mongo-recover
install -d -m 700 "$DST"
cp -a "$SRC"/. "$DST"/
chown -R 999:999 "$DST"
```

Create a temporary pod in the `rankstack` namespace. It uses a `hostPath` volume for the copy. It
has no Service and no Ingress.

```bash
NS=rankstack
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: mongo-recover
spec:
  restartPolicy: Never
  containers:
    - name: mongod
      image: mongo:7
      command: ["mongod", "--dbpath", "/scratch", "--bind_ip", "127.0.0.1"]
      volumeMounts:
        - {name: data, mountPath: /scratch}
      resources:
        requests: {memory: 256Mi}
        limits: {memory: 1Gi}
  volumes:
    - name: data
      hostPath: {path: /var/tmp/mongo-recover, type: Directory}
EOF
```

Use the image the old Deployment used if `mongo:7` cannot read the tree. The image version must
support the WiredTiger format. Do not run `mongod --repair` on the retained PVC.

Wait for the server:

```bash
until kubectl -n "$NS" exec mongo-recover -- mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; do
  sleep 3
done
```

## Inspect and dump

The database name is `rankstack` in the old deployment. Confirm it before you dump.

```bash
kubectl -n "$NS" exec mongo-recover -- mongosh --quiet --eval \
  'db.adminCommand({listDatabases:1}).databases.map(d => d.name)'

kubectl -n "$NS" exec mongo-recover -- sh -c \
  'mongodump --db rankstack --archive=/tmp/recovered.archive.gz --gzip'
kubectl cp "$NS"/mongo-recover:/tmp/recovered.archive.gz /var/tmp/recovered.archive.gz
```

Validate the archive before you delete anything:

```bash
kubectl -n "$NS" exec mongo-recover -- sh -c \
  'mongorestore --archive=/tmp/recovered.archive.gz --gzip --dryRun'
```

`--dryRun` lists what would restore and does not write. If the archive is valid, keep it. Do not
import it into a live database until the app owner confirms the target.

## Historical archive recovery

Use this only for an old `rankstack-rankstack-mongo.archive.gz` from a snapshot. Start a scratch
`mongo:7` instance on an **empty** directory. The old registry set `oplog: true`, so those archives
were taken with `mongodump --oplog`. Restore them with `--oplogReplay`. Without that flag the restore
stops at the dump start and discards the captured oplog. `--oplogReplay` works against a standalone
scratch instance. It does not require a replica set.

```bash
kubectl -n "$NS" cp /var/tmp/old.archive.gz mongo-recover:/tmp/old.archive.gz
kubectl -n "$NS" exec mongo-recover -- sh -c \
  'mongorestore --archive=/tmp/old.archive.gz --gzip --oplogReplay --drop'
```

Do not add `--oplogReplay` to the current raw-tree path or to a dump that was not taken with
`--oplog`. The current registry has no `mongo` target.

The old S0 bundle has no usable Mongo copy. Restic is the only source.

## Clean up

```bash
kubectl -n "$NS" delete pod mongo-recover
rm -rf /var/tmp/mongo-recover /var/tmp/recover-c
```

Delete the temporary pod. Do not delete the PVC, the PV, or the Secret. Do not leave a `mongod`
process on the retained tree.

## Status

The raw-tree check is part of the class-C restore drill on the 15th at 06:00 UTC. The drill finds
`WiredTiger` at depth 4 and requires a non-empty file plus a sibling `journal/` directory. It does
not run `mongod` and does not compare document counts. The last known document count (0 on
2026-09-28) was measured against the old running database and is historical.
