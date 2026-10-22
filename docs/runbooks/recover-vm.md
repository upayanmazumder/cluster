# Runbook: full VM loss recovery

Applies when the Hetzner server itself is gone or unrecoverable (hardware failure, accidental
deletion, etc.). The `vps-data` volume is separate and normally survives. That volume is what makes
this recoverable.

> **Cost of the loss, stated up front:** `/var/backups/restic` lives on the **root disk**. The
> node-local repository is gone with the server. Everything it held comes back from **Cloudflare R2**
> (`vps-backups`). The hourly `vps-backup-offsite.timer` copies the repository to R2. See
> [`../disaster-recovery.md`](../disaster-recovery.md) for the matrix.

## Procedure

```
Terraform (cluster/terraform, via scripts/tf.sh): provision a replacement server — same firewall,
   same SSH keys; TF_SECRETS restored from the password manager first
   → re-attach the surviving vps-data volume and MOVE the two primary IPs onto the new server
     (edit assignee_id / server_id; do NOT let Terraform create a new volume or new IPs)
Ansible (ansible/): ansible-playbook site.yml -e k3s_install_missing=true
   → base, tailscale, k3s (pinned version + config.yaml flags), data_volume (mounts /srv/data), backup
k3s: restore etcd from the latest R2 snapshot + matching server token/tls — see recover-k3s.md
   → this brings back node identity, RBAC, live-only Secrets, and ArgoCD's own state
   ...OR, if there is no snapshot to restore, bootstrap ArgoCD from git with k8s/bootstrap/bootstrap.sh
ArgoCD: selfHeal reconciles every git-tracked object back onto the new node
restic: restore what the volume does not hold (class-C local-path datasets, Grafana) from R2
images: the image tarballs come back with the restic `etcd` snapshot (step 6)
```

## Data that survives, and data that does not

| Data | Location | Survives server loss? | Recovery source |
|---|---|---|---|
| `vcap-v1` Postgres | `vps-data` volume, `/srv/data/vcap-v1-postgres` | Yes, if the volume is re-attached | Volume. R2 class-A logical dump is the fallback. |
| `vcap-staging` raw trees | `vps-data`, `/srv/data/vcap-staging` | Yes | Volume. R2 class-A raw copy is the fallback. |
| `vcap-dev` raw trees | `vps-data`, `/srv/data/vcap-dev` | Yes | Volume. R2 class-C raw copy is the fallback. |
| `meghmitra-postgres` | `vps-data`, `/srv/data/meghmitra-postgres` | Yes | Volume. R2 class-C raw copy is the fallback. |
| Adhigrahan Radar data | `vps-data`, `/srv/data/adhigrahan-radar-data` | Yes | Volume. R2 class-C copy is the fallback. |
| `vcap-v1` application data | root disk, local-path PVC | No | R2 class-A raw copy. |
| bitvault Postgres and MinIO | root disk, local-path PVs | No | R2 class-C raw copy. |
| rankstack Mongo | root disk, local-path PV | No | R2 class-C raw copy. |
| `kirro` mock data and voice logs | root disk, local-path PVs | No | R2 class-C raw copy. |
| Grafana database | root disk, `/var/lib/k8s-monitoring/grafana` | No | R2 class-C copy. |
| Prometheus, Loki | root disk, local-path | No | No restore. Metrics and logs are historical. |
| Live-only Secrets | etcd | No | R2 `etcd` snapshot. Rebuild from git otherwise. |

RPO for class A is 30 minutes plus the offsite lag, at most about one hour. RPO for class C is 24
hours plus the offsite lag. RTO has **not** been measured for the current target set.

## Step by step, with the gotchas that bite

**1. Provision with Terraform — from the `cluster` checkout, through `scripts/tf.sh`.** The
`vps` repository no longer holds Terraform configuration. `cluster/terraform` is the sole owner of
`s3://vps-tfstate/vps/terraform.tfstate`. First restore the provider credentials from the password
manager and point the wrapper at them:

```bash
# TF_SECRETS is the SOPS-encrypted provider env (Hetzner + Cloudflare + tfstate S3 keys).
# It lives OUTSIDE the repository. Restore it from the password manager to a path of your choosing.
export TF_SECRETS=<path to the restored provider-secrets file>
cd ~/dev/upayanmazumder/cluster
scripts/tf.sh plan -detailed-exitcode      # review: it must show only the server/IP/volume move
```

`scripts/tf.sh` refuses to run from any checkout whose `origin` is not
`upayanmazumder/cluster`. It snapshots state before any writer, and it injects the secrets with
`sops exec-env`. The server's `prevent_destroy` guard may need lifting deliberately. Do that
knowingly, not by reflex.

**2. Move the surviving assets onto the new server — do not recreate them.**

- **Primary IPs.** Both are `auto_delete=false` and delete-protected. They survive losing the
  server. Re-point them at the replacement by editing their `assignee_id`, or the server's
  `server_id` in the Terraform config, and applying. **Do not** let Terraform allocate new IPs.
  Every DNS record and the Origin CA wildcard stay pointed at the old address.
- **`vps_data`.** Re-attach the existing volume. `data_volume` deliberately refuses to `mkfs`. If
  the volume did not survive, class-A data comes from R2 instead. The role's safety check stops you
  from silently formatting an old volume.

**3. Ansible needs a route to the host, and the install flag.** `ansible/inventory.yaml` points at
the tailnet address. If Tailscale is not up on the control machine, override it. The exact command
is in the inventory comment. On a fresh server the pinned k3s is absent, and the k3s role refuses to
install it unless asked to. That is why `k3s_install_missing` exists:

```bash
cd ~/dev/upayanmazumder/cluster/ansible
ansible-playbook site.yml -e k3s_install_missing=true \
  -e ansible_host=138.201.157.147 -e ansible_ssh_private_key_file=<path to your key for this node>
```

Run it from `ansible/`. That directory loads `ansible.cfg` and the SOPS vars plugin. `data_volume`
mounts `/srv/data`. The `backup` role deploys the scripts and units. It does not start or enable any
timer. Enable the eight timers after you confirm the host. The host values — `k3s_node_ip`,
`k3s_node_external_ip` and the volume device — are derived. Pass
`-e data_volume_vps_linux_device=<terraform output -raw vps_data_linux_device>` so the replacement
host mounts the right volume. The node **must** be named `vps` (step 4).

**4. Restore etcd, or bootstrap from git, and keep the node name.** Either path works. Which path
depends on whether a snapshot exists:

- **If a snapshot exists:** restore per [`recover-k3s.md`](recover-k3s.md). Use the snapshot **and**
  the k3s server token and TLS from the *same* restic `etcd` snapshot. They travel together, so one
  restore gives a matched set. Pull it from R2, because the node-local repository died with the
  server.
- **If no snapshot exists:** re-bootstrap ArgoCD from git and accept the git-desired state as the
  starting point. Run `k8s/bootstrap/bootstrap.sh`. It creates the `argocd` namespace, installs
  `sops-age` from the offline age-cluster key, applies the SOPS-encrypted repo credentials,
  Helm-installs ArgoCD 7.9.1, waits for the repo server, and applies the app-of-apps root.

In both cases the node must be **`vps`**. Every PV carries `nodeAffinity: vps`. A node named
anything else leaves every claim `Pending`.

**5. Bootstrap order matters.** ArgoCD needs the `sops-age` key and the repository credentials
before it can read the SOPS-encrypted tree.

```bash
export AGE_CLUSTER_KEYS_FILE=/dev/shm/age-cluster/keys.txt   # from the password manager
k8s/bootstrap/bootstrap.sh
```

`bootstrap.sh` applies the credentials from `k8s/platform/argocd/secret/secrets.sops.yaml`. The
`vcap-v1` application repositories are public, so `repo-vcap-backend` and
`repo-vcap-frontend` are **not** v1 requirements. They target the retired
`vitscopesoftwareteam/VCAP-STAGING-*` repositories and exist for historical recovery only. Keep
`git-creds`, because the cluster repository itself still uses it.

The failure mode is a `ComparisonError: failed to get git client for repo` on every Application.
That happened on 2026-09-28 when the Secrets were re-homed (see
[`../../changelog/2026-09.md`](../../changelog/2026-09.md)). Every secret this cluster needs is
committed in SOPS form, so a rebuild loses nothing while one age private key survives. That is the
single most important fact on this page.

**6. Import image tarballs only if you need an image that no registry can serve.**
`vps-etcd-snapshot.sh` still exports tarballs into the restic `etcd` snapshot at
`/var/backups/images/*.tar`. This is historical baggage from the retired MinIO and bitvault
workloads. No current workload depends on those images. Do not spend time on this step unless a
specific recovery needs an image.

The old claim that `quay.io/minio/minio` returns 401 and that the owner's mirror was the only copy
is historical. The mirror `ghcr.io/upayanmazumder/mirror/minio` exists, and no current workload uses
it.

**7. Restore what the volume does not hold from R2.** Class C holds nine raw trees. They are
`vcap-dev`, Adhigrahan Radar, `meghmitra-postgres`, both bitvault PVCs, rankstack Mongo, both kirro
PVCs, and Grafana. Use the newest matching snapshot:

```bash
ssh vps 'set -a; . /etc/vps-backup/env; . /etc/vps-backup/r2.env; set +a; \
  restic snapshots --tag class-C --latest 1'
# Then restore the chosen snapshot into a scratch path and move the files into place.
```

The class-A snapshot holds the `vcap-v1` Postgres dump plus the raw `vcap-staging` tree and the raw
`vcap-v1` application data. Restore those to their static paths or their local-path PVC paths.

If the R2 copy is unavailable, the S0 bundle and the workstation mirror remain. Without either,
anything written after the S0 snapshot is lost.

**8. Re-apply workloads with the data in place.** For retained raw Postgres trees, use the
retired-data runbook: [`restore-postgres.md`](restore-postgres.md). For rankstack Mongo, use
[`restore-mongo.md`](restore-mongo.md). For retired MinIO trees, use
[`restore-minio.md`](restore-minio.md). These runbooks start a temporary pod on a **copy**. Do not
start Postgres or Mongo on the retained tree.

**9. Enable backups and confirm they work.** The `backup` role does not enable timers. On the new
host:

```bash
ssh vps 'systemctl list-timers "vps-*" --no-pager'
ssh vps 'systemctl start vps-backup-classA.service vps-backup-classC.service'
ssh vps 'journalctl -u vps-backup-classA -n 50 --no-pager'
```

All eight timers must be present: `vps-backup-classA`, `vps-backup-classC`,
`vps-etcd-snapshot`, `vps-backup-offsite`, `vps-backup-prune`, `vps-restic-check`,
`vps-restore-test`, and `vps-restore-test-c`.

**10. DNS.** No action is needed in the common case. Both primary IPs have `auto_delete=false` and
delete protection, and step 2 moves them onto the replacement. DNS keeps pointing at the same
addresses. Only a deleted IP requires record changes. The Origin CA wildcard in
`k8s/platform/traefik/` still matches because the hostname did not change.

**11. Validate.** Run these checks:

```bash
kubectl get nodes                                  # must be `vps`, Ready
kubectl get applications -n argocd -o wide
curl -s -o /dev/null -w '%{http_code}\n' https://vcap.upayan.dev          # 200
curl -s -o /dev/null -w '%{http_code}\n' https://argocd.upayan.dev        # 302
curl -s -o /dev/null -w '%{http_code}\n' https://status-page.upayan.dev   # 200
```

Then confirm the backup metric files advance:

```bash
ssh vps 'cat /var/lib/node_exporter/textfile_collector/vps_backup_classA.prom'
ssh vps 'cat /var/lib/node_exporter/textfile_collector/vps_backup_offsite.prom'
```

## Status

**Not exercised end-to-end for full VM loss.** The Terraform and Ansible path exists. Each step
has been run by hand against the live cluster, but the full sequence has not run on a throwaway VM.
Treat every RTO figure as a target.

The monthly drills do run. The class-A drill restores the class-A snapshot, imports the `vcap-v1`
logical dump, and compares row counts. It also validates every registered raw `file` tree. The
class-C drill restores the class-C snapshot, validates every raw tree, and checks the Mongo tree.
Both drills fail when a registered path is missing.
