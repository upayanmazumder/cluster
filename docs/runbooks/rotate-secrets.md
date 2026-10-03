# Runbook: rotate a secret

**Status:** the SOPS/age tooling is live and every `Secret` manifest under `k8s/` is encrypted
(converted 2026-09-28, stage S5) — so this procedure is executable today. What has *not* happened
is any actual rotation: the values in git are the original, unrotated credentials, and the
pre-conversion plaintext copies are still in git history. Rotation is what removes that exposure;
encryption alone does not, because history keeps the old values reachable. See
[`../secrets.md`](../secrets.md).

## Golden rule

**Deploy and verify the new credential before revoking the old one.** For credentials that have a
grace period (most API tokens), the old value keeps working while you prove the new one does — use
that window. Where the provider cannot hold two values at once (a database password), accept a
short, deliberate cutover and do it in one pass as described per credential below.

One credential at a time. Never bundle a rotation with an unrelated change, so a breakage has
exactly one candidate cause.

## Procedure

```bash
# sops finds the offline age key (age-ops) by default; the age-cluster key lives in-cluster

# 1. Edit the encrypted file in place -- sops decrypts to a temp file and re-encrypts on save.
sops k8s/apps/<app>/secrets.sops.yaml        # or k8s/platform/argocd/secret/secrets.sops.yaml, etc.

# 2. Prove it still renders the Secret you expect, before committing.
kustomize build --enable-alpha-plugins --enable-exec k8s/apps/<app>

# 3. Commit and push; ArgoCD reconciles in ~3 min (or hard-refresh the Application).
git commit -am "rotate <credential> for <app>" && git push origin main

# 4. Restart anything that reads the value only at process start (see per-credential notes),
#    then VERIFY the new credential actually works. Do not skip this step.
kubectl rollout restart deploy/<name> -n <namespace>

# 5. Only after step 4 passes: revoke the old credential at the source.
```

Naming: a credential that has not yet been rotated to its own new value at the provider is still
the leaked one.

## Per credential

### Hetzner API token (highest impact — full project write)

- **Lives:** `k8s/hetzner-csi/secrets.sops.yaml` → Secret `hcloud-csi` in `kube-system` (`key: token`).
  It can create/delete the server and volumes.
- **Consumed by:** the hcloud CSI driver (`k8s/hetzner-csi/values.yaml` sets `secretName: hcloud-csi`),
  and by Terraform / manual API calls via the `HCLOUD_TOKEN` environment variable.
- **Rotate:** mint a new token in the Hetzner console (project "vps"), *add* it alongside the old
  one so both are valid; put it in the Secret; then
  `kubectl -n kube-system rollout restart ds/hcloud-csi-node deploy/hcloud-csi-controller`.
- **Verify:** `kubectl -n kube-system logs ds/hcloud-csi-node --tail=20` shows no auth errors, and a
  throwaway PVC in any namespace reaches `Bound`.
- **Revoke:** delete the old token in the console. Also update whatever holds `HCLOUD_TOKEN` outside
  the cluster (the operator's shell/Terraform env).
- **Owner action required:** minting the token is console-only; the API cannot create tokens.

### Cloudflare Origin CA certificate/key (paired with S7)

- **Lives:** `k8s/platform/traefik/secrets.sops.yaml` → Secret `wildcard-upayan-dev-tls` in
  `kube-system`, referenced by `TLSStore default`. A **previous** Origin CA key is in git history;
  the certificate currently served is a newer one whose key was never committed — but the old
  certificate is still valid to 2040 and has not been revoked.
- **Verify after rotating:** origin-direct probe for any host, e.g.
  `echo | openssl s_client -connect 138.201.157.147:443 -servername bandit.upayan.dev 2>/dev/null | openssl x509 -noout -dates -ext subjectAltName`,
  then confirm `https://argocd.upayan.dev/` is `200` (a bad origin certificate shows up at Cloudflare
  as `526`).
- **Revoke:** the leaked 2025 certificate, in the Cloudflare dashboard (SSL/TLS → Origin Server),
  or via the API with a token holding **Origin CA: Edit**. This is the one S7 item still open.

### GitHub credentials

| Secret | Lives | Consumed by |
|---|---|---|
| `argocd-repo-vps`, `repo-vcap-backend`, `repo-vcap-frontend`, `git-creds` | `k8s/platform/argocd/secret/secrets.sops.yaml` | ArgoCD's repo access and image-updater's git write-back |
| `git-creds-updater`, `git-creds-noodle` | `k8s/platform/argocd-image-updater/secrets.sops.yaml`, `.../noodle/secrets.sops.yaml` | image-updater's git write-back, one write deploy key per repository it commits to |
| `bitvault-ghcr-pull` | `k8s/apps/bitvault/secrets.sops.yaml` | bitvault pod image pulls |
| `ghcr-creds` | **not in git** (live Secret only, 97d old) | `argocd-image-updater`, and it is currently **dead** (GitHub returns `401`) |
| `GITHUB_TOKEN` | `k8s/apps/kodesphere/secrets.sops.yaml`, `k8s/apps/upayan-web/secrets.sops.yaml` | those apps' own API calls |

- **Rotate:** mint the replacement (a classic PAT with `read:packages` for registry reads; read-only
  deploy keys per repo for ArgoCD; a fine-grained PAT limited to the repos image-updater writes, for
  `git-creds`). The plan's target is per-repo deploy keys rather than one reused `gho_` token — in progress: `git-creds-updater` (this repo) and `git-creds-noodle` (`Cheetos-gif/kirro`) are both deploy keys, so the image updater no longer depends on a `gho_` token at all.
- **Verify:** for the ArgoCD repo credentials specifically, force a reconcile of an Application that
  uses that repo and confirm it reaches `Synced` with no `ComparisonError: failed to get git client`
  — this is the chicken-and-egg described in [`recover-vm.md`](recover-vm.md), and the reason to keep
  the old value valid until the new one is proven.
- **Note:** `ghcr-creds` is not in git by design (it was created out-of-band); after rotating it,
  `argocd-image-updater` should stop logging `denied: denied` and start tracking digests again.

### Database passwords

| Target | Where the password is | Consumers |
|---|---|---|
| bitvault Postgres | `bitvault-postgres-env` + `bitvaultd-env` (`BITVAULT_DB_DSN`) | `bitvault-postgres`, `bitvaultd` |
| bitvault MinIO | `bitvault-minio-env` + `bitvaultd-env` (`BITVAULT_MINIO_*`) | `bitvault-minio`, `bitvaultd` |
| meghmitra Postgres | `meghmitra-postgres-env` + `meghmitra-api-env` (`DATABASE_URL`) | `meghmitra-postgres`, `meghmitra-api`, the ingest Job |
| vcap Postgres (dev + staging) | `backend-env` (`DATABASE_URL`, `DATABASE_URL_SYNC`) in `k8s/apps/vcap/secrets/<env>/secrets.sops.yaml` — **moved out of the values files 2026-09-29 (SEC-003)** | the vcap chart's api/worker/migrate/auth pods — **and this one needs an explicit `kubectl rollout restart` after the edit**, see below |

- **Why these need one pass:** Postgres cannot hold two passwords for one role, so the moment you
  `ALTER USER … PASSWORD` the consumers break until their Secret is updated. Order: update the
  Secret *and* the consumer env in the same commit, push, then `ALTER USER` and restart — or accept
  a few seconds of failed queries.
- **Verify:** `kubectl exec` a `psql` into the database with the new value, then confirm the app
  answers (meghmitra: `GET /documents` returns rows; bitvault: `api-bitvault.upayan.dev/healthz` is
  `200`; vcap: `api-vcap.upayan.dev/ping` is `200` and the `migrate` Job completes).
- **vcap specifically:** its password is no longer in a values file — since 2026-09-29 (SEC-003) it
  lives in `k8s/apps/vcap/secrets/<env>/secrets.sops.yaml` (`backend-env`). Rotating it properly is
  entangled with the per-person non-superuser roles the tenant's chart must first gain (OD-16) — see
  [`../secrets.md`](../secrets.md). The legacy public path is **closed**: 5432/5433 answer nothing and
  never reopen, and the target path (15432/15433) is **open** (verified 2026-09-29) — it opened once TLS,
  per-person roles, a network-superuser-locking `pg_hba` and auth-failure alerting exist. Editing the
  Secret does not roll the pods; follow it with a `kubectl rollout restart` (see the restart rule
  above).
- **Scope note:** the vcap chart's Postgres is currently shared by all devs as a single superuser;
  real rotation means the per-person roles the tenant agreement prescribes (OD-16), not just a new
  shared password.

### Discord webhooks / bot tokens

- **Lives:** `k8s/apps/mochi/secrets.sops.yaml` (`BOT_TOKEN`, `DISCORD_WEBHOOK_URL`),
  `k8s/apps/upayan-v5/secrets.sops.yaml` (`DISCORD_*`).
- **Rotate:** reset the bot token in the Discord developer portal, or delete and recreate the
  webhook. Both are owner actions (they need Discord account access).
- **Verify:** mochi logs a successful gateway login and a webhook post; `bots.upayan.dev` and
  `upayan-v5.upayan.dev` still answer `200`.

### Grafana credentials

- **Lives:** `k8s/monitoring/secrets.sops.yaml` — `grafana-admin-credentials` (`admin-user`,
  `admin-password`), `grafana-dev-credentials`, `grafana-staging-credentials`.
- **Consumed by:** `grafana-deployment.yaml` (admin env) and `grafana-create-dev-user-job.yaml`
  (which must never echo the value).
- **Rotate:** change the value in the Secret, then `kubectl -n monitoring rollout restart deploy/grafana`
  (Grafana reads its admin env at start). For the viewer accounts, update the Secret and re-run the
  user-provisioning Job.
- **Verify:** log in at `https://grafana.upayan.dev/` (expect `302` when unauthenticated; an actual
  login is the real test), and confirm the Job's logs do not contain the password.

## Other plaintext copies of these credentials, so nothing is forgotten

Encrypting the `Secret` manifests did not make this repo credential-free. The remaining plaintext
copies are:

- `k8s/apps/vcap/values/backend-{dev,staging}.yaml` — **DONE 2026-09-29 (SEC-003).** The vcap database
  URLs and the rest of the vcap credentials now live in
  `k8s/apps/vcap/secrets/{dev,staging}/secrets.sops.yaml`, exactly as this runbook predicted:
  `secrets.create: false`, `existingSecrets.backend`/`.auth`/`.imagePull` naming the Secrets, names
  unchanged, every workload still reading them by `secretKeyRef`/`envFrom`.
  **What this runbook assumed wrongly, and the correction:** it treated the blocker as needing the
  chart published to an HTTP Helm repo, because `kustomize --enable-helm` cannot run a ksops generator
  over a git-sourced chart. ArgoCD **multi-source** sidesteps it rather than solving it: the chart
  stays a Helm source and a *second* source in this repo (`path: k8s/apps/vcap/secrets/<env>`) is
  built by kustomize + ksops. One Application, so ownership, pruning and the Secret names are all
  unchanged.
- **New rule from the same change — the restart.** Those Deployments carry
  `checksum/secret: sha256(<rendered secret.yaml>)`. With the chart no longer rendering a Secret that
  checksum is constant, so **editing a value in `secrets.sops.yaml` will not roll the pods**, and the
  containers keep the old environment they read from `envFrom` at start. After any vcap credential
  edit:
  `kubectl rollout restart deploy/vcap-backend-<env>-api deploy/vcap-backend-<env>-auth deploy/vcap-backend-<env>-worker -n vcap-<env>`.
  (The move itself *did* roll them once, because the checksum changed as the template began rendering
  nothing.)
- `archived/docker/*.env` — **deleted from the tree 2026-09-29** (CLEAN-001); history only. Eight files
  from the retired docker-compose stack, several of which
  duplicate credentials of apps **still running in Kubernetes** (`mochi`, `kodesphere`, `cas-api`).
- `archived/**/secret*.yaml` — **deleted from the tree 2026-09-29** (CLEAN-001); history only. Plaintext
  exports of retired/deleted workloads, kept as audit
  records.
- Anything in **git history** — the pre-conversion plaintext `Secret` manifests, and every earlier
  commit that ever held a value.

None of these are fixed by re-encrypting or deleting a file: the old values stay reachable in
history. Rotation (this runbook) is what retires them; the history rewrite only removes the copies
that are no longer live.

## Rotation order (S5 — owner confirms each step)

Highest blast radius first, lowest last, so an early mistake is caught while the system is still
simple:

1. Hetzner API token
2. Cloudflare Origin CA certificate/key (with the S7 revocation)
3. GitHub credentials (ArgoCD repo + `git-creds` + `ghcr-creds`)
4. Discord webhooks/tokens
5. Database passwords — app and database together, one app at a time (vcap last, with S6)
6. Firebase service-account keys, Mongo Atlas password, other app secrets
7. Grafana admin/viewer credentials

## After all rotation is complete: git history rewrite

Only then, and only with explicit owner confirmation at each sub-step:

1. `git filter-repo` to remove the plaintext secret paths and inline values from history.
2. Verify with `gitleaks` over the full history that no real secret remains. **Baseline measured
   2026-09-28: 177 findings across 35 commits** — 134 `generic-api-key`, 17 `private-key`, 19 GitHub
   token variants, 4 `perplexity-api-key`, 2 `kubernetes-secret-yaml`, 1 `discord-client-secret`.
   The rewrite is only done when that number is **0** (or every remainder is a deliberate,
   documented false positive). Command:
   `gitleaks git . --redact --report-format json --report-path /tmp/history.json`.
3. A confirmed `git push --force` to `main`.

Why after: the rewrite does not neutralise anything by itself — old commits stay reachable via
cached SHAs and PR refs on GitHub. Rotation is what makes the leaked values dead; the rewrite only
stops them being *discoverable*.

## Related

- [`../secrets.md`](../secrets.md) — policy, SOPS/age recipients, the bootstrap-ordering caveat
- [`recover-vm.md`](recover-vm.md) — from-scratch bootstrap (apply the ArgoCD repo credentials first)
- [`rotate-certificates.md`](rotate-certificates.md) — the certificate side of S7
- [`../../.claude/skills/secrets-tls/SKILL.md`](../../.claude/skills/secrets-tls/SKILL.md) — day-to-day conventions
