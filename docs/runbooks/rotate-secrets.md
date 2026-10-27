# Runbook: rotate a secret

Every `Secret` manifest under `k8s/` is SOPS-encrypted. The `vcap-v1` workloads were retired on
2026-10-27. The v2 workloads were retired on 2026-10-23. Their namespaces, Secrets, PVCs, and PVs
remain for data recovery.

Encryption does not remove old values from git history. Rotation is what makes a leaked value dead.
See [`../secrets.md`](../secrets.md).

## Golden rule

Deploy and verify the new credential before you revoke the old one. Most API tokens allow two valid
values. Use that window. A database password does not allow two values for one role. Accept a short,
planned cutover for that case.

Rotate one credential at a time. Do not add an unrelated change. A failure must have one cause.

## Procedure

```bash
# 1. Edit the encrypted file in place.
sops k8s/apps/mochi/secrets.sops.yaml

# 2. Render the Secret before you commit.
kustomize build --enable-alpha-plugins --enable-exec k8s/apps/mochi

# 3. Commit and push. ArgoCD reconciles in about three minutes.
git commit -am "rotate <credential> for <app>" && git push origin main

# 4. Restart workloads that read the value at start.
kubectl -n <namespace> rollout restart deploy/<name>

# 5. Verify the new value. Then revoke the old value at the source.
```

## Hetzner API token

- **Secret:** `k8s/hetzner-csi/secrets.sops.yaml` → `hcloud` in `kube-system`, key `token`.
- **Consumer:** the hcloud CSI chart. The chart hardcodes Secret name `hcloud`. The old name
  `hcloud-csi` was inert and does not exist.
- **Also used by:** Terraform and manual API calls through `HCLOUD_TOKEN`.
- **Rotate:** create a new token in the Hetzner console. Keep the old token valid during the change.
  Write the new value to the Secret.
- **Restart:**
  ```bash
  kubectl -n kube-system rollout restart ds/hcloud-csi-node deploy/hcloud-csi-controller
  ```
- **Verify:** the CSI pods log no auth errors. A test PVC reaches `Bound`.
  ```bash
  kubectl -n kube-system logs ds/hcloud-csi-node --tail=20
  ```
- **Revoke:** delete the old token in the console. Update `HCLOUD_TOKEN` in the operator shell and
  Terraform environment.
- **Owner action:** only the console can mint a token.

## Cloudflare Origin CA certificate

- **Secret:** `k8s/platform/traefik/secrets.sops.yaml` → `wildcard-upayan-dev-tls` in `kube-system`.
- **Consumer:** `TLSStore default`. Every Ingress uses the default certificate.
- **Current leaf:** serial `699090E41816073595D26CDDE0568CFE6C66BCB7`, valid from 2026-09-28 to
  2027-09-28. SANs are `*.upayan.dev` and `vps.upayan.dev`.
- **Rotate:** follow [`rotate-certificates.md`](rotate-certificates.md). Generate a key and CSR.
  Issue the certificate in Cloudflare. Write `tls.crt` and `tls.key` with SOPS. Sync the
  `traefik-config` Application. Restart Traefik.
- **Verify:** read the loaded Secret and compare serial and dates. Use a public host:
  ```bash
  kubectl -n kube-system get secret wildcard-upayan-dev-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -serial -dates -subject -ext subjectAltName

  curl -sS -o /dev/null -w '%{http_code}\n' https://status-page.upayan.dev/
  curl -sS -o /dev/null -w '%{http_code}\n' https://argocd.upayan.dev/
  ```
  Expect `200` and `302`.
- **Alert:** `tls-cert-expiring` queries `traefik_tls_certs_not_after` and fires below 60 days.
- **Revoke:** revoke the old certificate in Cloudflare. This needs a token with `Origin CA: Edit`.
- **Owner action:** Cloudflare MFA is required for the dashboard path.

## GitHub credentials

| Secret | In git | Used by |
|---|---|---|
| `git-creds` | `k8s/platform/argocd/secret/secrets.sops.yaml` | ArgoCD access to this repository |
| `creds-github-upayanmazumder` | same file | GitHub account credential for `github.com/upayanmazumder/` |
| `repo-vcap-backend` | same file | ArgoCD access to `vitscopesoftwareteam/VCAP-STAGING-BACKEND` |
| `repo-vcap-frontend` | same file | ArgoCD access to `vitscopesoftwareteam/VCAP-STAGING-FRONTEND` |
| `git-creds-updater` | `k8s/platform/argocd-image-updater/secrets.sops.yaml` | image-updater git write-back over SSH |
| `ghcr-creds` | same file | image-updater registry access to GHCR |
| `vcap-v1/pull-secret` | retained, no workload | none (retired 2026-10-27) |
| `repo-creds-devlabs` | `k8s/platform/argocd/secret/repo-devlabs-secrets.sops.yaml` | ArgoCD URL-prefix credential for `upayanmazumder-DevLabs` |
| `git-creds-noodle` | live only | retained |
| `git-creds-rankstack` | live only | retained |

`argocd-repo-vps` does not exist. Do not add it.

The two `repo-vcap-*` credentials target the unused v2 staging repositories. The `vcap-v1`
Applications and AppProject were removed on 2026-10-27. `repo-creds-devlabs` is the ArgoCD
URL-prefix credential for the private `upayanmazumder-DevLabs` repositories.

- **Rotate a GitHub credential:** create the replacement at GitHub. A fine-grained PAT needs access
  to the exact repositories. An SSH deploy key must be unique to one repository. Write the value to
  the Secret.
- **Restart ArgoCD after a `git-creds` change:**
  ```bash
  kubectl -n argocd rollout restart deploy/argocd-repo-server
  kubectl -n argocd rollout status deploy/argocd-repo-server
  ```
- **Verify ArgoCD:**
  ```bash
  kubectl -n argocd annotate application mochi \
    argocd.argoproj.io/refresh=hard --overwrite
  kubectl -n argocd get application mochi
  ```
  The Application must reach `Synced`. There must be no `ComparisonError`.
- **Verify image-updater:**
  ```bash
  kubectl -n argocd logs deploy/argocd-image-updater-controller --tail=50
  ```
  The log must show no auth failure. A successful GHCR read and git write-back is the proof.
- **Revoke:** delete the old PAT, deploy key, or package token at GitHub.
- **Owner action:** GitHub account access is required.

Do not compare token fingerprints to `gh auth token`. That command returns a different string on
each call. Test the credential against the service.

## Database passwords

No database workload runs. The retained datasets have Secrets but no workload. Keep these Secrets
for recovery:

- `vcap-v1/backend-env` and `vcap-v1/auth-env` (retired 2026-10-27)
- `vcap-staging/backend-env`
- `vcap-dev/backend-env`
- `bitvault/bitvault-postgres-env`
- `meghmitra/meghmitra-postgres-env`

Do not rotate a retained Secret unless you restore the dataset. Do not start a workload to rotate it.

The `vcap-v1` Postgres edge on TCP 15434 is removed. No v1 password procedure exists. See
[`restore-postgres.md`](restore-postgres.md) to read the retained v1 data.

## Discord credentials

- **Secret:** `k8s/apps/mochi/secrets.sops.yaml` — `BOT_TOKEN` and `DISCORD_WEBHOOK_URL`.
- **Consumer:** `mochi`, exposed at `bots.upayan.dev`.
- **Rotate:** reset the bot token in the Discord developer portal. Recreate the webhook to replace
  its URL.
- **Verify:** mochi logs a gateway login and a successful webhook post. `https://bots.upayan.dev/`
  answers.
- **Revoke:** the old token or webhook is invalid after the reset.
- **Owner action:** Discord account access is required.

`upayan-v5` was retired. It no longer holds a Discord credential.

## Grafana credentials

- **Secret:** `k8s/monitoring/secrets.sops.yaml`:
  - `grafana-admin-credentials`
  - `grafana-dev-credentials`
  - `grafana-staging-credentials`
  - `grafana-kirro-credentials`
- **Consumers:** `grafana-deployment.yaml` reads the admin Secret. The PostSync hook
  `grafana-create-dev-user` reads all four Secrets.
- **Retained viewers:** the dev, staging, and kirro accounts are viewer accounts. Their workloads are
  retired. Keep the accounts and Secrets for retained dashboards. Do not delete them.
- **Rotate the admin password:** write the new value to the Secret. Restart Grafana:
  ```bash
  kubectl -n monitoring rollout restart deploy/grafana
  kubectl -n monitoring rollout status deploy/grafana
  ```
  Grafana reads the admin environment at start. The init container `reset-admin-password` also runs
  each start, so a password changed only in the UI returns to the Secret value after a restart.
- **Rotate a viewer password:** write the new value to the Secret. Force a sync of the `monitoring`
  Application. The `PostSync` hook has `BeforeHookCreation`, so ArgoCD replaces the old Job before the
  new run.
- **Verify:** `https://grafana.upayan.dev/` answers `302` when unauthenticated. Log in with the new
  value. The hook log must not print the password.

## After rotation

Confirm the old value fails and the new value works. Then remove the old value at the provider. Do not
leave two valid values unless the provider needs a grace period.

## History rewrite

The git history still contains old plaintext values. A history rewrite does not make them safe. It only
makes them harder to find. Rotate first.

Only with owner confirmation:

1. Run `git filter-repo` to remove plaintext secret paths and values from history.
2. Scan the full history:
   ```bash
   gitleaks git . --redact --report-format json --report-path /tmp/history.json
   ```
   The 2026-09-28 baseline was 177 findings across 35 commits. Treat that number as historical. The
   rewrite is done only when the count is zero or every remainder is a documented false positive.
3. Push with `git push --force` only after the owner confirms.

## Related

- [`../secrets.md`](../secrets.md): policy, SOPS and age recipients, bootstrap order.
- [`recover-vm.md`](recover-vm.md): from-scratch bootstrap.
- [`rotate-certificates.md`](rotate-certificates.md): the origin certificate.
- [`restore-postgres.md`](restore-postgres.md): recovery of the retained `vcap-v1` data.
- [`../../.claude/skills/secrets-tls/SKILL.md`](../../.claude/skills/secrets-tls/SKILL.md): daily
  conventions.
