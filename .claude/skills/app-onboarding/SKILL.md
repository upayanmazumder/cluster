---
name: app-onboarding
description: Step-by-step guide for adding a new application to the cluster, with all required files and copy-paste templates
---

# Adding a new application

Apps are **not** auto-discovered: the `apps` ApplicationSet uses a list generator, so a new
folder does nothing until you add a list element for it (step 6) and its namespace to the
`apps` AppProject (step 7).

## 1. Create folder

Folder: `k8s/apps/<app-name>/` (flat — there are no region subfolders).

ArgoCD app name will be `<app-name>` (the list element's `name`), namespace = `<app-name>`.

## 2. Required files

```
k8s/apps/<app>/
  deployments.yaml
  services.yaml
  ingress.yaml
  kustomization.yaml
  secret-generator.yaml      ← only if the app needs secrets
  secrets.sops.yaml          ← encrypted secret values
  persistentvolumeclaim.yaml ← only if the app needs storage
```

## 3. File templates

### `namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <app-name>
```

### `deployments.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app-name>
  namespace: <app-name>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <app-name>
  template:
    metadata:
      labels:
        app: <app-name>
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - vps
      containers:
        - name: <app-name>
          image: ghcr.io/<owner>/<image>:latest
          ports:
            - containerPort: 3000
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
```

### `services.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: <app-name>
  namespace: <app-name>
spec:
  selector:
    app: <app-name>
  ports:
    - port: 3000
      targetPort: 3000
```

### `ingress.yaml`
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app-name>
  namespace: <app-name>
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  rules:
    - host: <hostname>.upayan.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <app-name>
                port:
                  number: 3000
  # No tls: block — Traefik serves *.upayan.dev as the default cert automatically
```

### `kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app-name>
resources:
  - namespace.yaml
  - deployments.yaml
  - services.yaml
  - ingress.yaml
  # - secret.yaml
images:
  - name: ghcr.io/<owner>/<image>
    newTag: latest
```

## 4. Reference templates (copy from these)

- Single-service: `k8s/apps/learning-docker/`
- Multi-service (fe+be): `k8s/apps/bandit/`
- With PVC: `k8s/apps/smart-home-system-api/`
- Multi sub-folder: `k8s/apps/upayan-v5/`

## 5. DNS

Add in Cloudflare:
```
Type: A  Name: <hostname>  Content: 138.201.157.147  Proxy: ON
```

TLS is automatic — Traefik presents the `*.upayan.dev` wildcard cert for all routes.

## 6. Add a list element to the `apps` ApplicationSet

Append to `spec.generators[0].list.elements` in `k8s/argocd/applicationsets/apps.yaml`:

```yaml
- name: <app-name>                                   # Application name = folder = namespace
  imageList: 'app=ghcr.io/<owner>/<image>:latest'    # argocd-image-updater image-list
  alias0: app                                        # the alias used in imageList
  kustomize0: ghcr.io/<owner>/<image>                # = images[].name in kustomization.yaml
```

The template turns each element into an Application carrying the image-updater annotations
inline (`image-list`, `<alias0>.update-strategy: digest`, `<alias0>.kustomize.image-name`,
git write-back to `main`). `kustomize0` must equal the `images[].name` in `kustomization.yaml`
(the repo part of `imageList`, without the tag). This replaces the old per-app
`.argocd/image-updater.yaml` files, which were never read and have been removed.

Each element carries exactly **one** image. An app with two or more images (e.g.
`status-page`, `meghmitra`, `upayan-v5`) or a Helm/multi-source app does not fit the list
template: give it an explicit `Application` in `k8s/argocd/applications/apps/` instead (copy
`k8s/argocd/applications/apps/status-page.yaml`) and skip this step.

## 7. Add the namespace to the AppProject (required since S11)

The `apps`/`vcap` AppProjects no longer allow `namespace: "*"` — each one lists
its destinations explicitly. Add this app's namespace or the app will sync-fail with
`namespace <name> is not permitted in project apps`:

```
k8s/argocd/projects/apps.yaml
  destinations:
    - server: https://kubernetes.default.svc
      namespace: <app-name>
```

(`<app-name>` is the folder name, which is also the namespace the ApplicationSet
targets.) This is deliberate: it is the review gate for where a workload may land.
No change is needed for `platform`/`default` unless you are adding platform
infrastructure.

## 8. Commit and push

```bash
git add k8s/apps/<app-name>/ k8s/argocd/applicationsets/apps.yaml k8s/argocd/projects/apps.yaml
git commit -m "feat: add <app-name>"
git push origin main
```

Force immediate discovery (optional — ArgoCD also polls every ~3 min):
```bash
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=hard --overwrite
```

## 9. Verify

```bash
argocd app get <app-name>              # Synced / Healthy
kubectl get pods -n <app-name>         # Running
curl https://<hostname>.upayan.dev
```

## Secrets (if needed)

Never commit plaintext Secret manifests. Encrypt secrets with SOPS and age.

### `secret-generator.yaml`
```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: <app-name>-secrets-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secrets.sops.yaml
```

Add `secret-generator.yaml` under `generators:` in `kustomization.yaml`.
Create and encrypt `secrets.sops.yaml` using `sops`:
```bash
sops k8s/apps/<app-name>/secrets.sops.yaml
```
