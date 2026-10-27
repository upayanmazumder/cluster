# Secrets

All source `Secret` manifests under `k8s/` are SOPS-encrypted. vcap v1 was retired on 2026-10-27.
The retired v2 workloads were removed on 2026-10-23. Their namespaces, Secrets, PVCs, and
PVs remain for recovery.

Encryption is not rotation. A value that was ever committed is compromised. Rotation makes it dead.
See [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md).

## Current state

- **15 SOPS files** hold Kubernetes Secrets: 9 app files and 6 platform files.
- No plaintext `Secret` manifest remains under `k8s/`.
- The last plaintext credential path was the v2 Helm values file. That file is gone.
- `helm-secrets` is not installed. Kubernetes Secrets use the `ksops` generator.
- Terraform secrets use `sops exec-env`.
- Ansible secrets use the `community.sops` vars plugin.
- Every live workload reads its Secret from the cluster. No workload reads a git values file.

The old v2 Secret directories `k8s/apps/vcap/secrets/` do not exist. Do not add them back.

## Encryption

`.sops.yaml` at the repository root defines two age recipients. Either key decrypts.

1. `age-ops`: the owner workstation key. Keep an offline copy in the owner password manager.
2. `age-cluster`: installed as the `argocd/sops-age` Secret. ArgoCD repo-server uses it at runtime.

Losing both keys loses every git-held Secret. etcd snapshots of live Secret objects are the last
resort. See [`backups.md`](backups.md).

Rules:

- Kubernetes Secrets: encrypt only `data` and `stringData`. `kind`, `metadata`, and annotations stay
  readable and diffable.
- Ansible and Terraform files: encrypt the full document.
- Never commit a private age key.
- Never print a decrypted Secret value in shared output.

## ArgoCD decryption

- `k8s/platform/argocd/values.yaml` sets
  `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"`.
- The repo-server runs a digest-pinned `viaductoss/ksops:v4.5.1` init container.
- The init container installs `ksops` and a compatible `kustomize` into `/custom-tools`.
- The `sops-age` Secret mounts at the default age key path.
- Each generator lists `secrets.sops.yaml` under `files:`.

Test a generator locally:

```bash
kustomize build --enable-alpha-plugins --enable-exec k8s/apps/gitorgasm
```

CI does not decrypt. `scripts/check-secrets.sh` only checks `sops:` and `age:` metadata. Test the
plaintext build locally before a commit.

## Bootstrap order

On a new cluster, ArgoCD cannot read this private repository until its git credential exists. The
same is true for every other repository credential.

1. Restore `sops-age` by hand.
2. Decrypt and apply the ArgoCD Secret file:
   ```bash
   sops -d k8s/platform/argocd/secret/secrets.sops.yaml | kubectl apply -f -
   ```
3. Apply the ArgoCD Application. ArgoCD then reads the remaining files.

The old `argocd-repo-vps` Secret does not exist. Do not add it. The cluster repository uses
`git-creds`.

## Where each secret lives

| Secret | In git | Used by |
|---|---|---|
| `argocd-secret` | `k8s/platform/argocd/secret/secrets.sops.yaml` | ArgoCD server |
| `git-creds` | same file | ArgoCD access to this repository |
| `creds-github-upayanmazumder` | same file | GitHub access under `upayanmazumder/` |
| `repo-vcap-backend` | same file | ArgoCD access to the unused v2 staging backend repository |
| `repo-vcap-frontend` | same file | ArgoCD access to the unused v2 staging frontend repository |
| `repo-creds-devlabs` | `k8s/platform/argocd/secret/repo-devlabs-secrets.sops.yaml` | ArgoCD URL-prefix credential for `upayanmazumder-DevLabs` |
| `sops-age` | never | ArgoCD repo-server |
| `ghcr-creds` | `k8s/platform/argocd-image-updater/secrets.sops.yaml` | image-updater registry reads |
| `git-creds-updater` | same file | image-updater git write-back over SSH |
| `wildcard-upayan-dev-tls` | `k8s/platform/traefik/secrets.sops.yaml` | Traefik `TLSStore default` |
| `hcloud` | `k8s/hetzner-csi/secrets.sops.yaml` | hcloud CSI, key `token` |
| `grafana-admin-credentials` | `k8s/monitoring/secrets.sops.yaml` | Grafana admin |
| `grafana-dev-credentials` | same file | retained dev viewer |
| `grafana-staging-credentials` | same file | retained staging viewer |
| `grafana-kirro-credentials` | same file | retained kirro viewer |
| App Secrets | `k8s/apps/<app>/secrets.sops.yaml` | that application |
| `restic_password` | `ansible/group_vars/vps/secrets.sops.yaml` | restic backup repository |
| `admin_ssh_public_key` | same file | host access |
| R2 backup keys | never | `/etc/vps-backup/r2.env`, mode 0600 |
| Terraform secrets | never | external `secrets.enc.env`, read by `scripts/tf.sh` |
| age private keys | never | owner and `argocd/sops-age` |

The vcap v1 repositories under `upayanmazumder-DevLabs` are private and are not changed. No ArgoCD
Application reads them since 2026-10-27. ArgoCD reads other DevLabs repositories through
`repo-creds-devlabs`. An unauthenticated fetch returns `401`.

`git-creds-noodle` and `git-creds-rankstack` exist only in the live cluster. They have no source
manifest. They support retained workloads that no longer run. Do not make them a prerequisite.

## Retained live-only Secrets

These Secrets remain in their namespaces for data recovery. No workload mounts them. They are not in
git.

| Namespace | Secrets |
|---|---|
| `vcap-v1` | `auth-env`, `backend-env`, `pull-secret`, `vcap-v1-postgres-edge-tls` |
| `vcap-dev` | `auth-env`, `backend-env`, `pull-secret` |
| `vcap-staging` | `auth-env`, `backend-env`, `pull-secret` |
| `bitvault` | `bitvault-ghcr-pull`, `bitvault-minio-env`, `bitvault-postgres-env`, `bitvaultd-env` |
| `meghmitra` | `meghmitra-api-env`, `meghmitra-postgres-env` |
| `rankstack` | `rankstack-api-env` |
| `kirro` | `kirro-mock-admin`, `kirro-pinelabs`, `kirro-voice`, `kirro-whatsapp` |
| `bandit` | `bandit-secrets` |
| `upayan-v5` | `upayan-v5-api-env` |

Keep these Secrets until the owner deletes the retained data. Rotation is unnecessary while no
workload runs. If a dataset is restored, rotate its credential first.

The `upayan-api/upayan-api-env` Secret is managed through SOPS in
`k8s/apps/upayan-api/secrets.sops.yaml`. It uses the eight values from the retired
`upayan-v5-api-env` Secret. The old namespace remains retained, but it serves no workload.

## GitHub access

- ArgoCD uses repository-scoped credentials. This repository uses `git-creds`.
- The two unused v2 staging repositories use `repo-vcap-backend` and `repo-vcap-frontend`.
- The DevLabs prefix uses `repo-creds-devlabs`.
- image-updater uses `git-creds-updater` over SSH and `ghcr-creds` for the registry.
- The reused `gho_` token is not part of the current design.
- `git-creds-updater` writes image digests straight to `main`. Do not add a branch step.
- vcap v1 was removed on 2026-10-27. Its image pulls no longer exist. `vcap-v1/pull-secret` is retained and unused.

`ghcr-creds` works. Do not treat the old 401 incident as current. Verify with the image-updater pod
logs after a credential change.

## Rotation

Rotation order:

1. Hetzner API token.
2. Cloudflare Origin CA certificate and key.
3. GitHub credentials.
4. Database passwords.
5. Discord credentials.
6. Grafana credentials.

Owner confirmation is required at each external provider step. Deploy and verify the new value
before revoking the old value. The full procedure is in
[`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md).

Encryption alone does not reduce exposure. Git history still holds the old plaintext.

## History rewrite

Run a history rewrite only after rotation is complete and the owner confirms. Use `git filter-repo`,
then scan the full history with `gitleaks`. Push with `git push --force` only after the owner confirms.

The 2026-09-28 baseline was 177 findings across 35 commits. Treat that number as historical. A rewrite
does not neutralise a leaked credential. Rotation does.

## Logging hygiene

- Never run `kubectl get secret -o yaml` in shared output.
- Never echo a Grafana provisioning credential.
- Do not show decrypted SOPS output in a terminal that records scrollback.
- Do not paste a token into a command line. Use an environment variable or an interactive prompt.

## Related

- [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md): rotation procedure.
- [`certificates.md`](certificates.md): live TLS Secrets.
- [`runbooks/recover-vm.md`](runbooks/recover-vm.md): from-scratch bootstrap.
- [`../.claude/skills/secrets-tls/SKILL.md`](../.claude/skills/secrets-tls/SKILL.md): daily
  conventions.
