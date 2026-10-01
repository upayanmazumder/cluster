# Repository Guidelines

## Project Overview

GitOps source of truth for a single-node k3s cluster (`vps`, Hetzner DE, `138.201.157.147`) running
personal projects, portfolio apps, and a few club/team backends. **This is not a software
codebase** — it's Kubernetes manifests + ArgoCD `Application`/`ApplicationSet`/`AppProject`
resources. `main` is the only branch; every push is reconciled automatically by ArgoCD
(`selfHeal: true` on every app), so the git tree *is* the live cluster state.

## Architecture & Data Flow

```
k8s/bootstrap/root-app.yaml (applied once, manually, via kubectl)
  -> "root" Application, path k8s/argocd/, directory.recurse: true
       -> k8s/argocd/projects/{apps,platform,vcap}.yaml        (AppProject: sourceRepos allowlist)
       -> k8s/argocd/applications/{platform,apps,vcap}/*.yaml  (explicit Applications)
       -> k8s/argocd/applicationsets/apps.yaml                 (list generator, one element per app)
            -> element {name: <app>, ...}  ==>  Application "<app>"  (path k8s/apps/<app>, namespace = <app>)
```

Everything under `k8s/argocd/` is reconciled automatically — adding a file there and pushing to
`main` creates the resource within seconds. A folder under `k8s/apps/<app>/` is **not**
auto-discovered: the `apps` ApplicationSet uses a list generator, so adding an app also means
adding a list element (`name`, `imageList`, `alias0`, `kustomize0`) to
`k8s/argocd/applicationsets/apps.yaml` and its namespace to `k8s/argocd/projects/apps.yaml`.

Two deploy mechanisms coexist per app, chosen per app's complexity:
1. **Raw Kustomize in this repo** (most apps) — manifests live directly in `k8s/apps/<app>/`.
2. **Helm chart in the app's own repo** (`vcap`, `rankstack`) — this repo holds only a values
   overlay outside the `apps` ApplicationSet (`k8s/apps/<app>/values/*.yaml`);
   the chart itself lives in the app's GitHub repo. Multi-source `Application.spec.sources` wires
   the two together (see `k8s/argocd/applications/apps/rankstack.yaml`).

There was a **separate, non-Kubernetes deployment path** — `docker/docker-compose.yml` on the same
VPS, run under a restart loop (`live.sh`/`runner.sh`) with an image-poll/restart daemon
(`updater.sh`) behind a Caddy reverse proxy. **It is retired as of 2026-09-28, and its files were deleted from the tree on 2026-09-29**
(CLEAN-001); git history holds it. The evidence it is not
serving: its `Caddyfile` served the *same* hostnames as the Kubernetes Ingresses, and Traefik holds
80/443 on the node and answers those hosts, so Caddy cannot be bound. **It also contained `.env`
files duplicating live app credentials** — that material is now history-only, which is a reason not to
resurrect the directory, not a reason to rotate anything (the owner declined rotation; see the
migration plan's SEC-004).

**TLS: one default certificate, no per-app certs.** Traefik's default certificate is a Cloudflare
Origin CA wildcard (`*.upayan.dev`, `vps.upayan.dev`), set by the `TLSStore` named `default` in
`kube-system` (`k8s/platform/traefik/tlsstore.yaml`) pointing at
`kube-system/wildcard-upayan-dev-tls`, which is SOPS-encrypted in git
(`k8s/platform/traefik/secrets.sops.yaml`). Every served host is Cloudflare-proxied, so an Origin CA
cert is the right trust anchor. cert-manager has been removed, and there are no per-app TLS Secrets:
the only `kubernetes.io/tls` Secrets are that wildcard and k3s's own `kube-system/k3s-serving`.
Ingresses declare no `tls:` block. **It expires 2027-09-28** (issued 2026-09-28 for one year) and
nothing renews it automatically — a certificate-expiry alert is therefore required (`CLEAN-002`) and
renewal is a hand-run Origin CA procedure (`docs/runbooks/rotate-certificates.md`).

**Dead/unwired leftovers** (present in the tree, not part of the live platform — don't copy from
these): none right now. `k8s/keel/` (pre-Image-Updater polling manifests, no ArgoCD wiring) was
retired and is no longer in the tree. **Velero does not exist anywhere in `k8s/`** — it was never
committed; treat any mention of it elsewhere as stale, not current.

## Key Directories

| Path | Purpose |
|---|---|
| `k8s/bootstrap/` | One-time root Application, applied manually via `kubectl apply` |
| `k8s/argocd/projects/` | `AppProject`s: `apps`, `platform`, `vcap` — each scopes allowed `sourceRepos` |
| `k8s/argocd/applications/` | Explicit `Application` manifests: `platform/` components, `apps/` workloads needing multi-image/multi-source config, `vcap/` |
| `k8s/argocd/applicationsets/` | `apps.yaml` — list generator; one element per single-image app under `k8s/apps/` |
| `k8s/apps/<app>/` | Per-app Kustomize manifests; **folder name = namespace = ArgoCD app name** |
| `k8s/platform/` | Cluster-wide component values/config: `argocd`, `argocd-image-updater`, `traefik` (HelmChartConfig patch + `TLSStore default` + SOPS-encrypted wildcard Secret), `keda`, `keda-add-ons-http(-routes)`, `priority-classes` (no `velero/` — see note above) |
| `k8s/hetzner-csi/` | **Top-level, sibling to `k8s/platform/`, not inside it** — Hetzner CSI driver, vendored as `helm template` output checked into git (`render.sh` regenerates it) |
| `k8s/monitoring/` | Prometheus, Loki, Promtail, Grafana, kube-state-metrics, node-exporter, plus Grafana dashboard JSON and alert rules |
| `k8s/docs/` | **Removed 2026-09-29** (CLEAN-001) — its content was superseded by `docs/`; git history holds it. (`02-target-architecture.md`, `05-secrets-and-tls.md`, `06-image-automation.md`, `07-migration-runbook.md`, `09-backups.md`, etc.) |
| `k8s/bootstrap/README.md` | How the root Application is bootstrapped by hand — read this before any cluster-affecting setup |
| `changelog/` | Append-only forensic timeline, split `YYYY-MM.md`; **the** audit trail for git changes and break-glass kubectl |
| `.claude/skills/` | Operational playbooks (see Tooling below) |
| `.claude/agents/` | Sub-agent specs: `app-add`, `app-debug`, `cluster-ops` |
| `docs/` | Living operational documentation set (architecture, inventory, storage, backups, disaster recovery, ports, networking, secrets, certificates, monitoring, maintenance, upgrade policy, runbooks) |
| `.gitignore` | **No longer** excludes `k8s/monitoring/loki-configmap.yaml` (CLEAN-001 removed that stale ignore; the file is tracked) — but note the underlying gap still exists: that ConfigMap is live-edited outside git (see `docs/secrets.md`) |

## Development Commands

There is no build/compile step — manifests are applied by ArgoCD. Interaction is via `kubectl` and
`argocd` CLI, mostly read-only:

```bash
# Cluster/app status
kubectl get applications -n argocd -o wide
argocd app get <app-name>
argocd app diff <app-name>              # git desired vs cluster actual

# Force reconcile (preferred over sync for picking up a fresh push)
kubectl -n argocd annotate app <app> argocd.argoproj.io/refresh=hard --overwrite

# Rollback (preferred: git revert, not argocd app rollback)
git revert <sha> && git push origin main

# Break-glass only (see Hard Rules below) — restart after a Secret commit
kubectl rollout restart deploy/<name> -n <namespace>
```

Full command reference: `.claude/skills/argocd-ops/SKILL.md`.

## Code Conventions & Common Patterns

- **Naming:** app folder name = k8s namespace = ArgoCD Application name. `k8s/apps/bandit/`
  deploys as Application `bandit` into namespace `bandit`. For Helm-in-own-repo apps (see
  Architecture above) the chart is not under `k8s/apps/` — e.g. the now-archived `hello-kitty`
  existed only as an explicit Application sourcing `CodeChefVIT/hello-kitty` directly, with no
  `k8s/apps/hello-kitty/` folder (its export was deleted 2026-09-29 with the rest of the retired
  export tree; git history holds it).
- **Every app folder** has: `namespace.yaml`, `deployments.yaml`, `services.yaml`,
  `kustomization.yaml`, and `ingress.yaml` if externally exposed. `secret.yaml`/`secrets.yaml` and
  `persistentvolumeclaim.yaml` only if needed. See `k8s/apps/bandit/` (multi-service, fe+be) and
  `k8s/apps/learning-docker/` (single-service) as canonical examples.
- **Ingress TLS:** omit the `tls:` block entirely — Traefik serves the `*.upayan.dev` default
  certificate (see the TLS note above) — plus:
  ```yaml
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  ```
  Never add a `tls.secretName:` or a cert-manager annotation; neither the per-app Secret nor
  cert-manager exists any more.
- **Node affinity:** the cluster is single-node; every Deployment pins to `vps` via
  `nodeAffinity` on `kubernetes.io/hostname` (`preferredDuringScheduling...` in some apps,
  `requiredDuringScheduling...` in the onboarding template — check the app you're copying from).
- **Secrets:** SOPS-encrypted `Secret` manifests (`secrets.sops.yaml`) committed to this private
  repo, applied through a `ksops` generator (`secret-generator.yaml`) — no plaintext `Secret`
  manifest remains under `k8s/` since 2026-09-28. Both files are required per app directory, and
  every secret a workload needs **must** be committed so a clean rebuild works from git alone.
  The values are still the original unrotated credentials and remain in git history. The vcap Helm
  values files no longer carry credentials: since 2026-09-29 (SEC-003) the six vcap Secrets live in
  `k8s/apps/vcap/secrets/{dev,staging}/secrets.sops.yaml`, emitted by a ksops generator that is a
  separate multi-source of the same Application. See `.claude/skills/secrets-tls/SKILL.md`.
- **KEDA-scaled apps:** several apps scale 0↔1 via KEDA HTTP add-on (`httpscaledobject.yaml`
  alongside the Deployment). The `apps` ApplicationSet template carries an `ignoreDifferences`
  on `/spec/replicas` so ArgoCD doesn't fight KEDA over replica count — copy that pattern for new
  scale-to-zero apps rather than disabling self-heal.
- **Image automation:** apps wanting auto-deploy-on-push carry `argocd-image-updater.argoproj.io/*`
  annotations on their `Application` (not a separate CRD). Digest-tracking (`:edge` tag) can go
  either way on write-back — but **anything the `root` app-of-apps manages must write back to git**
  (`write-back-method: git:secret:argocd/git-creds-updater`). root owns those Application objects
  with `selfHeal` + `ServerSideApply`, so an **in-cluster** override (the bare default, no
  `write-back-method`) is deleted within seconds of image-updater writing it, and the app then
  oscillates between the pinned and unpinned revision — that is what restarted `rankstack`'s API pod
  ~22×/hour on 2026-10-01 (306 pods in 6h; see that day's changelog). A Helm-sourced app points
  `write-back-target` at a values file in this repo
  (`helmvalues:/k8s/apps/<app>/values/image.yaml`, rendered last so it wins) so the updater's commit
  lands where ArgoCD already reads values and the pin survives a rebuild from git alone; kustomize
  apps let it land in the app's `kustomization.yaml`. The `apps` ApplicationSet template sets the
  same git write-back. Semver tracking (`upayan-v5`) uses kustomize `images:` overrides instead. A
  per-app dedicated pull secret goes in `argocd-image-updater.argoproj.io/<alias>.pull-secret`.
  **ApplicationSet apps:** the per-app image list lives inline in each `apps` list element
  (`imageList`, `alias0`, `kustomize0`); the template renders it into `image-list`,
  `<alias0>.update-strategy: digest` and `<alias0>.kustomize.image-name` annotations, with git
  write-back to `main`. Historically the ApplicationSets used git directory generators, which
  expose only `path` and so could not give templated Applications per-app annotations; the
  per-app `.argocd/image-updater.yaml` files written back then were never read (inline
  documentation only) and have been removed as duplicated, drift-prone metadata.
- **Multi-image / Helm apps:** a list element carries exactly one image, and the template has no
  conditionals (a line starting with `{{` is not valid YAML inside the ApplicationSet manifest).
  Apps with two or more images or multi-source Helm (`status-page`, `meghmitra`, `upayan-v5`,
  `mochi`, `rankstack`) get an explicit `Application` in `k8s/argocd/applications/apps/` instead
  and **no** element in `apps.yaml` — having both would double-generate the Application.
- **Priority:** low-priority/best-effort workloads set `priorityClassName: low-priority` (defined
  in `k8s/platform/priority-classes/`).

## Important Files

- `k8s/bootstrap/README.md` — start here for any cluster question: bootstrap order, the root
  Application, and common-operation snippets.
- `k8s/bootstrap/root-app.yaml` — the only manifest ever applied by hand; bootstraps everything else.
- `k8s/argocd/applicationsets/apps.yaml` — the list of ApplicationSet-managed apps; read it
  before adding/removing an app folder (a folder with no element is not deployed).
- `k8s/argocd/projects/apps.yaml` (etc.) — `spec.sourceRepos` must list any external repo an
  `Application` sources from, and `spec.destinations` must list the app's namespace, or the sync
  fails project-scope validation.
- `changelog/README.md` + `.claude/skills/changelog/SKILL.md` — format contract for every change.

## Runtime/Tooling Preferences

No language runtime to install — this is a manifest repo. Required external tools when operating on
it: `kubectl`, `argocd` CLI, `git`. Plus `sops`/`age` for encrypted secrets (`kustomize` with
`--enable-alpha-plugins --enable-exec` to render a ksops directory) and `terraform`/`ansible` for
their directories. No package manager, no build tool, no formatter/linter is configured anywhere
in the repo (verified: no `.github/`, no lint config, no `Makefile`).

## Testing & QA

**There is no test suite, CI pipeline, or linter in this repo** (checked: no `.github/workflows`,
no pre-commit hooks, no schema-validation scripts, no test directories anywhere including
`docker/`). Correctness is validated entirely by ArgoCD's live reconciliation loop:

```bash
kubectl get applications -n argocd -o wide     # Synced+Healthy = correct
argocd app diff <app-name>                     # confirms git == cluster
kubectl get pods -n <namespace>                # Running = workload came up
curl https://<hostname>.upayan.dev             # end-to-end smoke test for exposed apps
```

Before declaring a change done: push to `main`, hard-refresh (`kubectl -n argocd annotate app root
argocd.argoproj.io/refresh=hard --overwrite`) if you don't want to wait for the ~3 min poll, then
check sync/health status and pod state as above. A changelog entry (see Code Conventions) is a hard
requirement for the change to count as complete — see `.claude/skills/changelog/SKILL.md` for the
exact entry format and required fields (`Actor`, `Type`, `Change`, `Reason`, `Verification`,
`Rollback`).
</content>
