# Secrets

Full detail: the architecture review (private, not published) §9.

## Current state

**No plaintext `Secret` manifest remains under `k8s/`** as of 2026-09-28 (stage S5 finished): all
21 app Secrets are in SOPS-encrypted `secrets.sops.yaml` files applied through `ksops` generators.
The last plaintext credential home in this repo — the Helm **values** files
(`k8s/apps/vcap/values/*.yaml`) — **closed 2026-09-29** (SEC-003). The six vcap Secrets
(`backend-env`, `auth-env`, `pull-secret` in `vcap-dev` and `vcap-staging`) now live in
`k8s/apps/vcap/secrets/{dev,staging}/secrets.sops.yaml`, emitted by a ksops generator that is a
**separate multi-source** of the same Application, with `secrets.create: false` so the chart stops
rendering them. That also resolved the blocker this file used to describe: a git-sourced Helm chart
cannot run a ksops generator inside `kustomize --enable-helm`, but it can carry a second source that
does. `helm-secrets` is still not installed and no longer has a use. What remains outside `k8s/`:
`.env` files. What has **not** changed: the credential *values* are the original, unrotated ones, and
everything ever committed (including the previous plaintext manifests, a Hetzner API token with full
project write, a reused GitHub `gho_` token, a Cloudflare Origin CA private key, Discord tokens,
Firebase service-account keys, a Mongo Atlas password and RSA keys) remains in git **history**.
Encryption is not rotation.

**This policy is being superseded** (owner decision, 2026-09-27): secrets are moving out of
plaintext git. `../.claude/CLAUDE.md` rule 4 and `../AGENTS.md` still describe the old
plaintext-forever convention as the default for most apps — S5 has landed for the *tooling* and
and, as of 2026-09-28, for **all** app Secret manifests — no plaintext `Secret` manifest remains
under `k8s/`. The credential rotation that has to follow encryption has **not** started (see
"Rotation order" below).

## S5 status: SOPS + age + ksops — live, and no credential is plaintext in git

Chosen over Sealed Secrets (its controller-held key is itself something to back up, and you can't
read your own secrets from git) and External Secrets/Vault (needs a backing store + operator RAM
this single-node cluster doesn't need).

- **Encryption**: `.sops.yaml` (repo root) — `encrypted_regex: ^(data|stringData)$` for
  `k8s/**/secrets.sops.yaml` Secret manifests (kind/metadata stay readable/diffable), full-value
  encryption for `ansible/**/secrets.sops.yaml` and `terraform/secrets.enc.env`.
- **Two age recipients** (either can decrypt) — both generated this session:
  1. `age-ops` — the owner's workstation key, in sops' default location on the owner's own
     machine (the exact path this doc always specified). **Still needed: an offline copy in the
     owner's password manager** — not done yet, needs the owner's own password-manager access.
  2. `age-cluster` — installed as the `argocd/sops-age` Secret via break-glass kubectl (never
     committed to git, per the changelog entry for this stage).
  Losing both means losing git-held secrets; etcd snapshots of the running cluster's live Secrets
  remain a last resort (see [`runbooks/recover-k3s.md`](runbooks/recover-k3s.md)).
- **Bootstrap order (learned the hard way, 2026-09-28):** the repo credentials
  (`argocd/git-creds`, `argocd/argocd-repo-vps`, `argocd/repo-vcap-backend`,
  `argocd/repo-vcap-frontend`) live SOPS-encrypted in
  `k8s/platform/argocd/secret/secrets.sops.yaml`. That file is read *from the private repo ArgoCD is
  trying to fetch*, so on a fresh cluster (or if those Secrets are ever lost) ArgoCD cannot
  self-heal: every Application reports `ComparisonError: failed to get git client for repo
  https://github.com/upayanmazumder/vps`. Restore them by hand first —
  `sops -d k8s/platform/argocd/secret/secrets.sops.yaml | kubectl apply -f -` — then ArgoCD resumes
  on its next reconcile. Same step as `runbooks/recover-vm.md`'s from-scratch bootstrap.
- **ArgoCD**: the repo-server has `ksops` (a Kustomize exec plugin) live —
  `k8s/platform/argocd/values.yaml` pins a real, digest-verified `viaductoss/ksops:v4.5.1`
  initContainer that installs `ksops` + a compatible `kustomize` into the repo-server's PATH, plus
  the `sops-age` Secret mounted into the repo-server at sops' default age-key location and
  `configs.cm.kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"` (required for
  kustomize to run any exec plugin at all). Verified live: `k8s/apps/cheatsheet` converted from
  a plaintext `secret.yaml` to a `ksops` generator + `secrets.sops.yaml`; the live
  `cheatsheet-web-env` Secret's `resourceVersion`/pod were untouched by the conversion (decrypted
  value was byte-identical to the prior plaintext) — `argocd` and `sg-cheatsheet` (now `cheatsheet`) both
  `Synced`/`Healthy` after the repo-server rolled with the new init container.
  **`helm-secrets` (for Helm-chart apps' values files) is not added yet** — only the
  kustomize-based `ksops` path is live; every other app in this repo uses plain `kustomization.yaml`
  + resource files like cheatsheet did, so this covers the common case first.
- **Terraform** secrets: the SOPS ciphertext `secrets.enc.env` (Hetzner token, Cloudflare token,
  tfstate S3 keys), consumed via `sops exec-env`. The rule is in `.sops.yaml`; the file **exists but
  lives outside every repository** (OD-10, restored from the password manager) — `cluster/terraform`
  is the sole owner and `cluster/scripts/tf.sh` reads it from that external path.
- **Ansible** secrets: `ansible/group_vars/vps/secrets.sops.yaml` via the `community.sops` vars
  plugin, decrypted in-flight. **In use**: it holds `restic_password` (rendered to
  `/etc/vps-backup/env`, mode 0600) and `tailscale_auth_key` / `admin_ssh_public_key`. The R2 backup
  credentials are deliberately **not** here — they are host-local in `/etc/vps-backup/r2.env` and
  never pass through Ansible, SOPS or git (the `cluster`-owned offsite leg reads them only on the
  node).
- **GitHub access**: the reused `gho_` token is replaced — ArgoCD reads repos with read-only
  deploy keys (per repo); image-updater's git write-back uses a fine-grained PAT scoped to exactly
  the repos it writes (or a per-repo write deploy key). **Not started** — still using the existing
  `gho_` token.
- **Rotation order** (owner confirms each step; new credential deployed and verified before the
  old one is revoked) — see [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md) for the full
  procedure: Hetzner API token → Cloudflare Origin CA cert/key (paired with S7) → GitHub tokens →
  Discord webhooks/tokens → DB passwords (app + DB together, one app at a time) → Firebase SA
  keys, Mongo Atlas password, other app secrets → Grafana admin/viewer credentials. **Not started**
  — encryption tooling landing is the prerequisite for this, not the same step; the values are now
  encrypted in git but are still the real, unrotated credentials.
- **Git history rewrite**: planned only *after* rotation is fully done, each sub-step confirmed by
  the owner. `git filter-repo` removes plaintext secret files/paths and inline secrets, verified
  with `gitleaks` over the full history, then a confirmed `git push --force` to `main`. Rotation
  (not the history rewrite) is what actually neutralises a leaked credential — old commits stay
  reachable via cached SHAs/PR refs on GitHub regardless.
- **Logging hygiene**: never `kubectl get secret -o yaml` in shared output; the Grafana
  user-provisioning Job must not echo credentials.
- **CI**: `scripts/check-secrets.sh` fails the build if any `secrets.sops.yaml` file is missing
  real `sops:`+`age:` metadata (catches an accidentally-committed plaintext file under that name).
  CI holds no decrypt key by design — the plaintext `kubectl kustomize` build step in
  `.github/workflows/validate.yml` skips `ksops`-generator directories; converting an app is
  verified locally instead (`kustomize build --enable-alpha-plugins --enable-exec`) before commit.

## Where each secret lives

Condensed from the migration plan's secret-placement table (P4-05); "never" rows are never committed
anywhere, public or private.

| Secret | Off-machine (password manager + offline medium) | On the node | Generated at bootstrap | In git |
|---|---|---|---|---|
| age-ops private key | **yes** (DR-002) | no | no | never |
| age-cluster private key | **yes** | as `argocd/sops-age` | no | never |
| restic password | yes | `/etc/vps-backup/env` | no | SOPS `ansible/group_vars/vps/secrets.sops.yaml` |
| R2 backup S3 key pair + endpoint | **yes** | `/etc/vps-backup/r2.env` | no | never |
| `secrets.enc.env` (Hetzner/Cloudflare/tfstate) | **yes**, as a file | no | no | never (it lives outside every repository — OD-10) |
| VCAP Postgres edge private CA key | **yes, only there** | no | once (P2-08) | never |
| VCAP Postgres edge TLS leaf | via SOPS | in-cluster Secret `vcap-postgres-edge-tls` | once per renewal | SOPS `k8s/apps/vcap/edge/<env>/tls.sops.yaml` |
| Grafana admin / vcap-dev / vcap-staging credentials | via SOPS (+ handed to VCAP out-of-band) | in-cluster | vcap-* generated in P1-01 | SOPS `k8s/monitoring/secrets.sops.yaml` |
| Per-person Postgres role passwords | owner's password-manager share per person | in Postgres only | yes (P2-08) | never |
| Tailscale auth key | no (one-off) | consumed at join | per rebuild: ephemeral, pre-authorised, revoked after join | never |
| ArgoCD GitHub credential and `git-creds` | via SOPS | in-cluster | no | SOPS `k8s/platform/argocd/secret/secrets.sops.yaml` |
| image-updater write-back keys (`git-creds-updater`, `git-creds-noodle`) | via SOPS | in-cluster | no | SOPS `k8s/platform/argocd-image-updater/secrets.sops.yaml`, `.../noodle/secrets.sops.yaml` |
| `argocd-secret`, GHCR pull secrets, Origin CA TLS, app Secrets | via SOPS | in-cluster | no | SOPS |
| k3s server token + CA | inside restic `etcd` snapshots | `/var/lib/rancher/k3s/server` | yes (no-etcd path) | never |

## Related

- [`runbooks/rotate-secrets.md`](runbooks/rotate-secrets.md) — the rotation procedure, still pending
  (encryption tooling landing is not the same as rotation happening)
- [`certificates.md`](certificates.md) — the Origin CA and private-CA keys will become SOPS Secrets
  once rotated (S7), same as any other app secret
- [`../.claude/skills/secrets-tls/SKILL.md`](../.claude/skills/secrets-tls/SKILL.md) — current
  operational conventions (mostly still pre-S5; only `cheatsheet` uses the new pattern so far)
