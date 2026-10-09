# Repository Guidelines for Agents

## Project Overview

This repository is the single source of truth for the k3s cluster on Hetzner Cloud.
All cluster state lives in `k8s/`.
The cluster runs personal projects, portfolio services, and team backends.
This repository contains Kubernetes manifests, ArgoCD resources, Ansible playbooks, and Terraform configurations.
The `main` branch is protected.
Seven required CI checks validate every pull request.
Do not push directly to `main`.
Create a feature branch and open a pull request.
ArgoCD reconciles merged changes automatically.

## Architecture and Data Flow

```
k8s/bootstrap/root-app.yaml (applied once with kubectl)
  -> "root" Application watches k8s/argocd/ recursively
       -> k8s/argocd/projects/*.yaml        (AppProjects configure sourceRepos and namespaces)
       -> k8s/argocd/applications/*/*.yaml  (Explicit Applications for platform, apps, vcap)
       -> k8s/argocd/applicationsets/*.yaml (List generator generates single-image applications)
            -> {name: <app>}  ==>  Application "<app>" (path k8s/apps/<app>, namespace = <app>)
```

ArgoCD reconciles resources under `k8s/argocd/` automatically.
Applications under `k8s/apps/<app>/` are not auto-discovered.
To deploy a new application, complete two registration steps:
1. Add an item to `k8s/argocd/applicationsets/apps.yaml`.
2. Add the namespace to `k8s/argocd/projects/apps.yaml`.

Workloads use two deployment patterns:
1. **Kustomize in this repository**: Manifests live directly in `k8s/apps/<app>/`.
2. **Multi-source Helm charts**: The chart lives in an external repository. This repository holds only a values overlay.

## Hard Rules

1. **Do not use `kubectl apply/create/delete/patch/edit` for persistent cluster state.**
   ArgoCD enables `selfHeal: true` on all applications except `hetzner-csi`.
   Manual `kubectl` changes revert within minutes.
   Persistent changes must go through git.

2. **Permitted break-glass kubectl operations:**
   - `kubectl apply -f k8s/bootstrap/root-app.yaml` (apply root application once).
   - `kubectl rollout restart deploy/<name> -n <ns>` (restart pods after secret updates).
   - `kubectl delete pod <name> -n <ns>` (delete a stuck pod).
   - `kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite` (force sync).

3. **Secrets must use SOPS and age encryption.**
   Never commit plaintext Secret manifests under `k8s/`.
   Store encrypted secrets in `secrets.sops.yaml`.
   Use `secret-generator.yaml` with the `ksops` generator plugin.

4. **Log every cluster change in the changelog.**
   Record git changes and break-glass operations in `changelog/YYYY-MM.md`.
   Commit the changelog entry in the same commit for git changes.
   Commit break-glass entries immediately after the manual operation.

## Code Conventions and Best Practices

- **Naming**: Use the same name for the application folder, namespace, and ArgoCD application.
- **Namespaces**: Reference `../../components/namespace-baseline` in `kustomization.yaml` for namespace and PSA labels.
- **Node affinity**: The cluster has one node. Pin all Deployments to the `vps` node.
- **Ingress TLS**: Omit the `tls:` block from Ingress manifests.
  Traefik terminates TLS using the Cloudflare Origin CA default certificate.
  Add the entrypoint annotation:
  ```yaml
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  ```
- **Image automation**: Use `argocd-image-updater.argoproj.io/*` annotations for automatic deployments.
  Always set `write-back-method: git:secret:argocd/git-creds-updater`.
  The updater commits digest pins back to `main`.
- **KEDA scale-to-zero**: Add an `ignoreDifferences` entry on `/spec/replicas` in the Application manifest.
  This setting prevents ArgoCD from conflicting with KEDA replica scaling.
- **Priority classes**: Set `priorityClassName: low-priority` on non-critical workloads.

## Key Directories

| Directory | Purpose |
|---|---|
| `k8s/bootstrap/` | Root Application manifest and bootstrap documentation |
| `k8s/argocd/projects/` | AppProject resources with repository and namespace allowlists |
| `k8s/argocd/applications/` | Explicit Application manifests for complex workloads |
| `k8s/argocd/applicationsets/` | ApplicationSet list generator for single-image applications |
| `k8s/apps/<app>/` | Workload manifests (one folder per application) |
| `k8s/platform/` | Platform infrastructure: Traefik, ArgoCD, KEDA, priority classes |
| `k8s/monitoring/` | Prometheus, Grafana, Loki, Promtail, and alert rules |
| `ansible/` | Host configuration playbooks for k3s, Tailscale, and backups |
| `terraform/` | Cloudflare and Hetzner infrastructure managed with `scripts/tf.sh` |
| `docs/` | Architecture, runbooks, and disaster recovery procedures |
| `changelog/` | Append-only changelog entries split by month |
| `scripts/` | Local verification scripts for CI parity |
| `.claude/skills/` | Operational task playbooks |
| `.claude/agents/` | Sub-agent definitions for common workflows |

## Operational Skills

Use operational skills located in `.claude/skills/`:

| Skill | Purpose |
|---|---|
| `app-onboarding` | Instructions and templates to add a new application |
| `argocd-ops` | Command reference for ArgoCD sync, refresh, and diff |
| `changelog` | Standards and format for changelog entries |
| `cluster-state` | Live topology, application inventory, and project map |
| `cluster-validation` | Local validation scripts and pre-commit checks |
| `secrets-tls` | Secrets policy, SOPS usage, and TLS certificate reference |

## Sub-Agents

Three sub-agents assist with cluster operations in `.claude/agents/`:

- `app-add`: Scaffolds a new application folder and registers it in ArgoCD.
- `app-debug`: Diagnoses degraded or failing ArgoCD applications.
- `cluster-ops`: Inspects live cluster state, retrieves logs, and triggers syncs.

## Validation and QA

Run local validation scripts before opening a pull request:

```bash
# Verify application paths in manifests
python3 scripts/check-app-paths.py

# Verify documentation links
python3 scripts/check-links.py

# Verify secret encryption and SOPS metadata
bash scripts/check-secrets.sh

# Run shellcheck on scripts
bash scripts/check-shellcheck.sh

# Render Kustomize manifests
bash scripts/render-all.sh /tmp/all-manifests.yaml

# Render Helm manifests
bash scripts/helm-template-all.sh /tmp/helm-manifests.yaml
```

CI runs these checks automatically on pull requests.
All checks must pass before merging to `main`.
