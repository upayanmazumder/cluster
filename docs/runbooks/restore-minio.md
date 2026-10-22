# Runbook: recover retired MinIO file trees

This runbook applies to three retained object trees. Their MinIO workloads were retired on
2026-10-23. The namespaces, Secrets, and PVCs remain.

| Dataset | Host path | Backup class |
|---|---|---|
| `vcap-staging` MinIO | `/srv/data/vcap-staging/minio` | A |
| `vcap-dev` MinIO | `/srv/data/vcap-dev/minio` | C |
| `bitvault` MinIO | `/var/lib/rancher/k3s/storage/pvc-acbed98f-94ef-414e-a6bf-ad69882db2d7_bitvault_bitvault-minio-pvc` | C |

The retired `hello-kitty` tree is out of scope. It has no backup target because the application no
longer exists.

All three trees use a single-drive MinIO layout. Data is stored as plain files plus metadata under
`.minio.sys`. A file-level copy is sufficient to preserve the data. The metadata must stay with the
objects if you want MinIO to serve them again.

## What is backed up

The registry in `ansible/files/backup-targets.yaml` uses `engine: file` for all three paths. Restic
reads the directories directly. There is no MinIO server to query.

- Class A runs every 30 minutes. It covers `vcap-staging`.
- Class C runs daily. It covers `vcap-dev` and `bitvault`.

The snapshots also cover the rest of `/srv/data/vcap-staging` and `/srv/data/vcap-dev`. Those
directories also hold the retained Postgres trees and `artifacts/`.

Skip `.minio.sys/tmp/` when you copy by hand. It holds scratch and trash files that change
constantly. The backup and drill code excludes it.

## 1. Restore from restic

Pick the newest snapshot for the class that contains the dataset:

```bash
ssh vps 'set -a; . /etc/vps-backup/env; . /etc/vps-backup/r2.env; set +a; \
  restic snapshots --tag class-A --latest 1'
ssh vps 'set -a; . /etc/vps-backup/env; . /etc/vps-backup/r2.env; set +a; \
  restic restore latest --tag class-A --target /tmp/minio-restore'
```

For class C, replace `class-A` with `class-C`. The restored tree keeps the source path:

- `/tmp/minio-restore/srv/data/vcap-staging/minio`
- `/tmp/minio-restore/srv/data/vcap-dev/minio`
- `/tmp/minio-restore/var/lib/rancher/k3s/storage/pvc-acbed98f-..._bitvault_bitvault-minio-pvc`

Do not restore directly over the live tree. Restore to scratch, inspect it, then copy the files you
need.

## 2. Check the tree before you use it

```bash
du -sh /tmp/minio-restore/srv/data/vcap-staging/minio
find /tmp/minio-restore/srv/data/vcap-staging/minio -maxdepth 1 -mindepth 1 -type d
```

For vcap, the bucket directories are `vcap-artifacts` and `vcap-workspace`. For bitvault, the bucket
is `bitvault`.

Confirm `.minio.sys/buckets` exists. MinIO needs it to recognize the buckets. If `.minio.sys` is
missing, the objects are still recoverable as files, but MinIO will not serve them as buckets.

The monthly drill validates every registered `file` tree. It restores the snapshot and diffs each
restored tree against the live directory. That proves file presence and content. It does not start a
MinIO server. A server-level bucket test remains a manual check.

## 3. Recover files without a server

If you need the objects, not a running MinIO:

```bash
sudo cp -a /tmp/minio-restore/srv/data/vcap-staging/minio/vcap-artifacts/. \
  /srv/data/vcap-staging/artifacts/
```

Use the destination that the consuming application expects. Do not start a retired workload to
serve the data.

## 4. Optional: inspect with a temporary MinIO server

Run MinIO only when you must validate bucket metadata. Use a **copy**, never the retained tree. Do
not create a Service, Ingress, or firewall rule. Do not expose the data.

```bash
sudo mkdir -p /var/tmp/minio-check
sudo cp -a /tmp/minio-restore/srv/data/vcap-staging/minio/. /var/tmp/minio-check/

kubectl -n default apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: minio-check
spec:
  restartPolicy: Never
  containers:
    - name: minio
      image: ghcr.io/upayanmazumder/mirror/minio:RELEASE.2025-04-22T22-12-26Z
      command: ["minio", "server", "/data", "--address", "127.0.0.1:9000"]
      env:
        - name: MINIO_ROOT_USER
          value: localcheck
        - name: MINIO_ROOT_PASSWORD
          value: localcheck-only
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      hostPath:
        path: /var/tmp/minio-check
        type: Directory
EOF

kubectl -n default port-forward pod/minio-check 9000:9000
```

Open `http://127.0.0.1:9000` and sign in with the temporary credentials. The pod has no Service,
no Ingress, and no public port. Delete it when the check ends:

```bash
kubectl -n default delete pod minio-check
```

## Image note

The old `quay.io/minio/minio` image is not available upstream. That claim is historical. The owner
published `ghcr.io/upayanmazumder/mirror/minio`, and no current workload uses it. Do not recreate the
retired Deployments.

An image tarball remains in the restic `etcd` snapshot at `/var/backups/images/*.tar`. Import it only
if you need that exact image.

## Do not

- Do not recreate `deployment/bitvault-minio` or any retired vcap MinIO Deployment.
- Do not scale a Deployment that no longer exists.
- Do not expose recovered object data through a Service, Ingress, or public port.
- Do not write into a retained tree before you have a verified copy.
