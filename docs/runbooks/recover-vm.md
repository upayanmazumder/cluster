# Runbook: full VM loss recovery

Applies when the Hetzner server itself is gone or unrecoverable (hardware failure, accidental
deletion, etc.). The `vps-data` volume is separate and normally survives — which is what makes this
recoverable at all.

> **Cost of the loss, stated up front:** `/var/backups/restic` lives on the **root disk**, so the
> node-local repository is gone with the server. Everything it held — class-A dumps, class-C
> datasets, etcd snapshots, the unrepullable image tarballs — comes back from **Cloudflare R2**
> (`vps-backups`), which the hourly `vps-backup-offsite.timer` has been copying to since 2026-09-29.
> Anything that predates the offsite leg, or that R2 does not have, comes from the S0 bundle or the
> workstation mirror. See [`../disaster-recovery.md`](../disaster-recovery.md) for the matrix.

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
images: the unrepullable-image tarballs now come back with the restic `etcd` snapshot (step 7)
```

RPO ≈ 0 for class-A data once `vps-data` is re-attached: it is a separate Hetzner volume and holds
`vcap-staging`, `vcap-dev` and the tenant datasets as static `Retain` PVs. RTO target ~2 hours —
**unverified**; the P4-09 drill on a throwaway VM exists to measure it.

## Step by step, with the gotchas that bite

**1. Provision with Terraform — from the `cluster` checkout, through `scripts/tf.sh`.** The
`vps` repository no longer holds Terraform configuration (P3-04/P3-06); `cluster/terraform` is the
sole owner of `s3://vps-tfstate/vps/terraform.tfstate`. Before anything runs, restore the provider
credentials from the password manager to their expected location and point the wrapper at them:

```bash
# TF_SECRETS is the SOPS-encrypted provider env (Hetzner + Cloudflare + tfstate S3 keys);
# it lives OUTSIDE the repository (OD-10), restored from the password manager to a path of your
# choosing. `scripts/tf.sh` defaults to it there and honours TF_SECRETS if you put it elsewhere.
export TF_SECRETS=<path to the restored provider-secrets file>   # from the password manager
cd ~/dev/upayanmazumder/cluster
scripts/tf.sh plan -detailed-exitcode      # review: it must show only the server/IP/volume move
```

`scripts/tf.sh` refuses to run from any checkout whose `origin` is not
`upayanmazumder/cluster`, snapshots state before any writer, and injects the secrets with
`sops exec-env`. The server's `prevent_destroy` guard may need lifting deliberately — do that
knowingly, not by reflex.

**2. Move the surviving assets onto the new server — do not recreate them.**

- **Primary IPs.** Both are `auto_delete=false` and delete-protected, so they survive losing the
  server. Re-point them at the replacement by editing their `assignee_id` (or the server's
  `server_id` in the Terraform config) and applying — **do not** let Terraform allocate new IPs, or
  every DNS record and the Origin CA wildcard stay pointed at an address nothing answers on.
- **`vps_data`.** Re-attach the existing volume. `data_volume` deliberately refuses to `mkfs`; if
  the volume did *not* survive, class-A data comes from R2 instead — and the role's safety check is
  what stops you from silently formatting an old one.

**3. Ansible needs a route to the host, and the install flag.** `ansible/inventory.yaml` points at
the tailnet address; if Tailscale is not up on the control machine, override it (the exact command
is in the inventory's comment). On a fresh server the pinned k3s is absent, and the k3s role refuses
to install it unless asked to — that is the whole reason `k3s_install_missing` exists:

```bash
cd ~/dev/upayanmazumder/cluster/ansible
ansible-playbook site.yml -e k3s_install_missing=true \
  -e ansible_host=138.201.157.147 -e ansible_ssh_private_key_file=<path to your key for this node>
```

Run it from `ansible/` (that is what loads `ansible.cfg` and the SOPS vars plugin). `data_volume`
mounts `/srv/data`; `backup` deploys the scripts and units but starts nothing. The host values —
`k3s_node_ip`, `k3s_node_external_ip` and the volume device — are derived (P4-03); pass
`-e data_volume_vps_linux_device=<terraform output -raw vps_data_linux_device>` so the replacement host
mounts the right volume. Also note the node **must** be named `vps` (step 4).

**4. Restore etcd — or bootstrap from git — and keep the node's name.** Either path works; which
one depends on whether a snapshot exists:

- **If a snapshot exists:** restore per [`recover-k3s.md`](recover-k3s.md), using the snapshot **and**
  the k3s server token/TLS from the *same* restic `etcd` snapshot (they travel together, so one
  restore gives a matched set) — pulled from R2, since the node-local repository just died with the
  server.
- **If no snapshot exists:** re-bootstrap ArgoCD from git instead and accept the git-desired-state
  as the starting point. That is `k8s/bootstrap/bootstrap.sh`, which creates the `argocd` namespace,
  installs `sops-age` from the offline age-cluster key, applies the SOPS-encrypted repo credentials,
  Helm-installs ArgoCD 7.9.1, waits for the repo server, and applies the app-of-apps root.

  In both cases the node must be **`vps`** — all PVs carry `nodeAffinity: vps`, so a node named
  anything else leaves every claim `Pending`. `vps-rebuild` is only the DR-006 drill server's name.

**5. Bootstrap order matters, and it bites.** Private repositories require credentials
before ArgoCD can fetch them (`repo-vcap-backend`, `repo-vcap-frontend`). Those are committed
SOPS-encrypted in `k8s/platform/argocd/secret/secrets.sops.yaml`. Apply them before the root app,
or run `bootstrap.sh`:

```bash
export AGE_CLUSTER_KEYS_FILE=/dev/shm/age-cluster/keys.txt   # from the password manager (P4-01)
k8s/bootstrap/bootstrap.sh
```

Skipping this shows up as `ComparisonError: failed to get git client for repo
https://github.com/upayanmazumder/vps` on every Application — which really happened on 2026-09-28
when those Secrets were re-homed (see [`../../changelog/2026-09.md`](../../changelog/2026-09.md)).
As of that date **every secret this cluster needs is committed in SOPS form**, so a rebuild loses
nothing as long as one age private key survives. That is the single most important thing on this
page.

**6. Import the MinIO image before vcap's MinIO starts, if the tarball is needed.**
`quay.io/minio/minio:RELEASE.2025-04-22…` **cannot be pulled from any registry** (upstream returns
401), and the live deployments now run the owner's mirror
(`ghcr.io/upayanmazumder/mirror/minio`, pushed 2026-09-28) — but before that mirror existed the only
copy was the node's containerd cache. The exported tarballs ride in the restic `etcd` snapshot
(`/var/backups/images/*.tar`) and in the S0 bundle:

```bash
# from the restic etcd-tag restore, or the S0 bundle
ssh vps 'k3s ctr images import /root/pre-migration-2026-09/minio-RELEASE.2025-04-22.tar'
```

`ghcr.io/upayanmazumder/bitvault/bitvaultd` is also private: restore it from the node cache if that
survived, otherwise it needs the owner's `read:packages` token.

**7. Restore what the volume does not hold** — the class-C `local-path` datasets (bitvault, rankstack,
grafana) and Grafana's sqlite — from **R2**, using the newest matching snapshot:

```bash
ssh vps 'set -a; . /etc/vps-backup/env; . /etc/vps-backup/r2.env; set +a; \
  restic snapshots --tag class-C --latest 1'
# then restic restore of the chosen snapshot into a scratch path, and move the files into place
```

If the R2 copy is somehow unavailable the S0 bundle and the workstation mirror (`scripts/pull-backups.sh`)
remain; without either, anything written after the S0 snapshot is lost.

**8. DNS.** **No action needed in the common case.** Both primary IPs have `auto_delete=false` and
delete protection, and step 2 moves them onto the replacement — DNS keeps pointing at the same
addresses. Only if an IP itself was deleted do the records need re-pointing, and the Origin CA
wildcard in `k8s/platform/traefik/` still matches because the hostname did not change.

**9. Validate:** `kubectl get nodes` (it must be `vps`, `Ready`), `kubectl get applications -n argocd
-o wide`, then spot-check a few `https://<host>.upayan.dev` endpoints and one authenticated one
(`https://argocd.upayan.dev`).

## Status

**Never exercised end-to-end.** The Terraform/Ansible path exists and each step has been run by hand
against the live cluster, but the full sequence has not been run on a throwaway VM — that is P4-09,
and until it runs, treat the ~2 hour RTO above as a target rather than a measurement. What *has* been
measured is the class-A database restore path: the monthly drill restores, imports and row-count-verifies
both databases in under five minutes.
