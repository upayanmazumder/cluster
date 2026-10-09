# cluster — Kubernetes GitOps repository

This repository is the single source of truth for the k3s cluster on Hetzner DE.
All cluster state lives in `k8s/`.
Push changes to `main`.
ArgoCD reconciles changes automatically.
Use `kubectl` for break-glass operations only.
The `selfHeal: true` setting reverts manual changes within minutes.

## Hard rules

1. **Do not use `kubectl apply/create/delete/patch/edit` for changes that belong in git.**
   The `selfHeal: true` policy is active on every application except `hetzner-csi`.
   Manual `kubectl` changes revert within minutes.
   Persistent cluster changes must go through git: edit `k8s/`, create a commit, and push to a branch.
   Then open a pull request to merge into `main`.

2. **Permitted break-glass kubectl operations:**
   - `kubectl apply -f k8s/bootstrap/root-app.yaml` (root application bootstrap).
   - `kubectl rollout restart deploy/<name> -n <ns>` (restart pods after a Secret change).
   - `kubectl delete pod <name> -n <ns>` (terminate a failed pod).
   - `kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite` (force sync).

3. **Use only the `main` branch.**
   Do not create long-lived branches.

4. **Secrets use SOPS encryption (`secrets.sops.yaml`).**
   Do not commit plaintext `Secret` manifests under `k8s/`.
   Each application directory contains a `secrets.sops.yaml` file.
   The `ksops` generator applies these secrets.
   Never display secret values in shared output.
   Edit secrets with `sops k8s/apps/<app>/secrets.sops.yaml`.

5. **Log every cluster change in the changelog.**
   This rule includes git changes under `k8s/` and break-glass `kubectl` writes.
   Record entries in `changelog/YYYY-MM.md` in the same commit.
   For break-glass operations, commit the entry immediately after the action.

## Workflow

1. Edit files under `k8s/`.
2. Commit changes to a feature branch.
3. Push the branch to GitHub.
4. Verify that all CI checks pass.
5. Merge the pull request into `main`.
6. ArgoCD reconciles the cluster state within three minutes.

Direct pushes to `main` fail because CI status checks are required.
Run `git pull` before pushing.
The `argocd-image-updater` commits image digest updates directly to `main`.
Do not revert these updates.

## Cluster facts

- Node: `vps` running k3s in Hetzner DE (`138.201.157.147`).
- ArgoCD app-of-apps: root application watches `k8s/argocd/` on `main`.
- AppProjects: `platform`, `apps`, `vcap`, `bootstrap`.
- TLS: Traefik default certificate is a Cloudflare Origin CA wildcard (`*.upayan.dev`).
  The secret is SOPS-encrypted in `k8s/platform/traefik/`.
  Ingress resources do not declare a `tls:` block.
- Secrets: SOPS and age encrypt every secret in git.

## Directory map

```
k8s/
  bootstrap/root-app.yaml       Root app manifest for initial bootstrap
  argocd/
    projects/                   AppProjects with allowed source repositories
    applications/               Explicit Application manifests
    applicationsets/            ApplicationSet list generator for apps
  apps/                         Workload manifests (folder = namespace = app name)
  platform/                     argocd, argocd-image-updater, keda, traefik
  monitoring/                   Prometheus, Grafana, Loki, Promtail
ansible/                        Host configuration playbooks
docs/                           Architecture and operations documentation
scripts/                        Validation and maintenance scripts
terraform/                      Hetzner and Cloudflare infrastructure
```

## Known issues and workarounds

| Item | Status | Cause and resolution |
|---|---|---|
| `smart-home-system-api` | Fragile | Persistent volume points to a deleted volume. Volume fails to attach on scale from zero. |
| `adhigrahan-radar` | Replaced `meghmitra` | Adhigrahan Radar replaced the legacy PostGIS Meghmitra deployment. |
| ArgoCD sync delay | Operational | ArgoCD can report Synced at an older revision. Run hard refresh annotation to force update. |
| `api-bandit.upayan.dev` | 502 Bad Gateway | The backend does not bind port 5000 because MongoDB Atlas rejects connection. |
| Two-level domains | Edge TLS error | Cloudflare Universal SSL covers single wildcards only. Use single-level hyphenated hostnames. |

## Sub-agents available

- `.claude/agents/cluster-ops`: inspect live cluster state, view logs, and trigger syncs.
- `.claude/agents/app-add`: scaffold a new application folder and register it in ArgoCD.
- `.claude/agents/app-debug`: diagnose degraded or out-of-sync applications.

## Reference documents

- `.claude/skills/cluster-state/SKILL.md`: full cluster inventory and project map.
- `.claude/skills/app-onboarding/SKILL.md`: guide for adding new applications.
- `.claude/skills/argocd-ops/SKILL.md`: ArgoCD command reference.
- `.claude/skills/secrets-tls/SKILL.md`: secrets policy and TLS configuration.
- `.claude/skills/changelog/SKILL.md`: changelog format requirements.
- `docs/README.md`: primary operational documentation index.
