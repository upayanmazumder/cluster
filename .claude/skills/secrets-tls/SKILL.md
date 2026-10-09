---
name: secrets-tls
description: Secrets policy (SOPS+age, ksops) and TLS certificate management reference for this cluster
---

# Secrets & TLS reference

## Secrets policy

**Decision:** secrets are `Secret` manifests in `upayanmazumder/cluster`. Their `stringData`
is encrypted with SOPS and age (`secrets.sops.yaml`). A `ksops` generator applies each secret.
No Sealed Secrets exist. No external secret store exists.

**Every app Secret is converted as of 2026-09-28** — there is no plaintext `Secret` manifest under
`k8s/`. Two caveats that matter: the credential *values* are the **original, unrotated** ones, and
the old plaintext values remain in git **history**. Rotation order and the post-rotation
`git filter-repo` + `gitleaks` rewrite live in `../../docs/secrets.md` and are owner-gated.

The Helm **values** files are no longer a plaintext home: the vcap Secrets moved to
`k8s/apps/vcap/secrets/{dev,staging}/secrets.sops.yaml` (SEC-003, 2026-09-29), emitted by a ksops
generator in a **separate multi-source** of the same Application. That is how the long-standing
"a git-sourced Helm chart cannot run ksops" blocker was resolved — not by publishing the chart, which
the runbook assumed was the only route. `helm-secrets` is still not installed and still not needed.

**Consequence:** the vcap api/auth/worker Deployments carry `checksum/secret` over the chart's own
`secret.yaml`, which now renders nothing — so **a credential edit no longer rolls those pods**. After
changing one, run `kubectl rollout restart deploy/<name> -n vcap-{dev,staging}`.

Keys: `.sops.yaml` at the repo root names two age recipients (`age-ops`, the owner's workstation key
at the offline age key's default location; and `age-cluster`, installed as the `argocd/sops-age` Secret and
mounted into the repo-server at `/.config/sops/age`). Either can decrypt.

### Bootstrap credentials (they cannot bootstrap themselves)

`argocd/git-creds`, `argocd/repo-vcap-backend`, and `argocd/repo-vcap-frontend` are encrypted
in `k8s/platform/argocd/secret/secrets.sops.yaml`. Private repositories require these credentials.
If these Secrets are missing, apply them manually:

```bash
# sops finds the offline age key by default; set SOPS_AGE_KEY_FILE only if yours lives elsewhere
sops -d k8s/platform/argocd/secret/secrets.sops.yaml | kubectl apply -f -
```

### Invariant

Every secret a workload references **must be a committed manifest** so a clean cluster rebuilds from git alone.

### Changing a secret

```bash
# Edit in place -- sops decrypts to a temp file and re-encrypts on save.
# Requires the offline age key, which sops finds by default
sops k8s/apps/<app>/secrets.sops.yaml
git commit -am "update <secret-name>"
git push origin main

# Force pod restart if the app reads env only at startup:
kubectl rollout restart deploy/<name> -n <namespace>
```

Verify before pushing that the encrypted file still renders to the same Secret:

```bash
SOPS_AGE_KEY_FILE="<path to the offline age key>" \
  kustomize build --enable-alpha-plugins --enable-exec k8s/apps/<app>
```

Without `SOPS_AGE_KEY_FILE`, ksops fails with `Error getting data key: 0 successful groups`.

### Secret template

`k8s/apps/<app>/secrets.sops.yaml` — created as plaintext, then `sops -e -i`'d in place (the
`.sops.yaml` rule matches on the `k8s/**/secrets.sops.yaml` path, so it must be encrypted at its
final path, not from `/tmp`). `kind`/`metadata` stay readable; only `stringData` is encrypted:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <app>-env
  namespace: <app>
type: Opaque
stringData:
  KEY: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
```

Plus `k8s/apps/<app>/secret-generator.yaml`, which is what actually applies it:

```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: <app>-secrets-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secrets.sops.yaml
```

…and `generators: [secret-generator.yaml]` in that directory's `kustomization.yaml`, with the old
plaintext file **removed from `resources:` and deleted**. CI's plaintext build pass skips any
directory containing `kind: ksops`.

### Image pull secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-<app>
  namespace: <app>
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64-of-docker-config-json>
```

### Secrets currently in git

**App secrets:** `vcap-*-env`, `cas-api-env`, `bandit-secrets`, `cheatsheet-web-env`, `upayan-web-env`, `smart-home-system-api-env`, `kodesphere-env`, `github-private-key` (kodesphere PEM mount)

**Platform secrets:** `git-creds` (Image Updater git write-back PAT), `ghcr-creds` (**dead/unused** — dead PAT; the updater reads GHCR anonymously, so don't reach for it when something can't pull)

## TLS

### Architecture

One wildcard cert `*.upayan.dev` (SAN `*.upayan.dev`, `vps.upayan.dev`) — a **Cloudflare Origin CA**
certificate, not ACME. **It expires 2027-09-28** (issued 2026-09-28 for one year) and **nothing renews
it automatically**, so a hand-run renewal is an obligation with a date — not the 15-year non-issue the
docs used to describe. An expiry alert is required (`CLEAN-002`); renewal is
`docs/runbooks/rotate-certificates.md`.
Traefik presents it as the **default certificate** via the `TLSStore` named `default` in `kube-system`.
Individual Ingresses need **no `tls:` block** — just host rules.

cert-manager was removed (2026-09-28): there is no `ClusterIssuer`/`Certificate` to create, and no
per-app `*-tls` Secrets. The only `kubernetes.io/tls` Secrets in the cluster are
`kube-system/wildcard-upayan-dev-tls` and `kube-system/k3s-serving` (k3s-managed, leave alone).

Every host this cluster serves is Cloudflare-proxied, which is why an Origin CA cert (trusted only by
Cloudflare) is correct.

### Where it lives

- `k8s/platform/traefik/secrets.sops.yaml` — the `kube-system/wildcard-upayan-dev-tls` Secret, SOPS-encrypted
- `k8s/platform/traefik/tlsstore.yaml` — the `TLSStore`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: kube-system
spec:
  defaultCertificate:
    secretName: wildcard-upayan-dev-tls
```

### Check the served cert

```bash
kubectl -n kube-system get tlsstore default
kubectl -n kube-system get secret wildcard-upayan-dev-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Issuer should be Cloudflare Origin CA, and the SANs should be `*.upayan.dev` + `vps.upayan.dev`.
**Do not check `notAfter` against a date written in a doc** — an expiry claim belongs to one specific
certificate and every reissue invalidates it (the docs said 2041 for months after the served
certificate became a one-year one). As of 2026-09-28 the live value is `notAfter 2027-09-28`.

### DNS for new hostnames

Every new hostname needs a Cloudflare record:
```
Type: A   Name: <hostname>   Content: 138.201.157.147   Proxy: ON
```

Full (Strict) SSL mode required (Cloudflare proxied + Traefik serving a valid cert).
