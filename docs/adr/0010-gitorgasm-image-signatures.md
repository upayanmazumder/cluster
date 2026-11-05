# 0010 — Verify gitorgasm image signatures with a namespace-scoped Sigstore controller

**Status:** Proposed (warning-only GitOps rollout; enforcement requires the gates below)
**Date:** 2026-11-05

## Context

The gitorgasm reusable `image-publish.yml` workflow signs the pushed GHCR manifest-list digest using GitHub Actions OIDC and cosign 3.1.4. Publishing a signature alone does not verify an image when Kubernetes admits it. This cluster does not yet have an image-signature admission controller. The tenant owns its Namespace and workload manifests in the gitorgasm repository; this repository owns platform security controls. Other applications and gitorgasm's Postgres image must remain unaffected.

## Decision

Install Sigstore `policy-controller` through the platform ArgoCD project, using pinned Helm chart **0.10.8** from `https://sigstore.github.io/helm-charts`. Override its default controller v0.13.1 with **v0.15.1**, pinned to the GHCR image-index digest `sha256:0492bb264fb1d9bdc8e3f343ef542cc85b7dd7c7fd8d9524b453c2bd31a1d128`. Version 0.14 adds OCI 1.1 discovery, 0.15 adopts cosign v3, and 0.15.1 updates TUF trusted-root retrieval. The older chart default is therefore not the verifier for new cosign v3 bundles. Keep the chart's CRDs; our policy uses fields served by its v1beta1 schema. The cleanup image is separately digest-pinned rather than inheriting `latest-dev`.

Both workload webhooks select **only** namespaces whose API-server-managed `kubernetes.io/metadata.name` is `gitorgasm`. This avoids a tenant-controlled opt-in label and excludes `policy-controller`, `kube-system`, `argocd`, monitoring, and every other tenant. The `ClusterImagePolicy` matches only the exact repository `ghcr.io/upayanmazumder/gitorgasm/core` (tag or digest references, not repositories beginning with `core`). Images without a matching policy are allowed, so Postgres is not accidentally denied by the upstream default.

Require a cryptographically verified Sigstore **bundle**, public-good Sigstore trust material from TUF, and the exact certificate identity:

- OIDC issuer: `https://token.actions.githubusercontent.com`
- SAN subject: `https://github.com/upayanmazumder/gitorgasm/.github/workflows/image-publish.yml@refs/heads/main`

The expected SAN is the reusable signing workflow (`job_workflow_ref`), not caller `ci.yml`, the environment name, or an arbitrary workflow in the repository. Do not broaden this to a repository-wide regular expression if verification fails. Inspect the real certificate and correct the exact identity instead. This is image-signature provenance, **not** a claim of SLSA predicate or SBOM verification.

Begin with `spec.mode: warn` and workload `failurePolicy: Ignore`. Failed signatures warn rather than prevent restarts, and controller outages cannot block gitorgasm during observation. The policy-object admission webhooks remain upstream fail-closed; they only handle policy/trust-root writes, not application workloads. No warning-only rollout is represented as enforcement.

Use one controller replica on node `vps`, requests 50m CPU/128Mi, limits 250m/384Mi, and no single-replica disruption budget. These are configured budgets, not measured consumption. The namespace uses the shared Pod Security baseline. A separate policies Application retries bootstrap while CRDs and the webhook become available. Server-side apply avoids CRD annotation-size limits. ArgoCD ignores only controller-generated certificate/rule/config data; namespace selectors and failure policies remain reconciled.

## Promotion gates and live validation

Merge/deploy the warning-only change before testing admission. All persistent changes, including promotion and rollback, go through reviewed GitOps PRs; do not install the chart or patch policies with kubectl.

1. Confirm both Applications are Synced/Healthy, `policy-controller-webhook` is Available, and `gitorgasm-core-signed` is Ready. Confirm the live workload webhook selectors contain only `gitorgasm`, their services point to namespace `policy-controller`, and the policy-controller namespace is excluded.
2. Verify the exact manifest-list digest published after signing was introduced, then confirm api and worker use that digest in their **spec**. A container runtime imageID can be a platform-specific child digest and is not a substitute for the signed index digest.

   ```bash
   cosign verify \
     --certificate-identity 'https://github.com/upayanmazumder/gitorgasm/.github/workflows/image-publish.yml@refs/heads/main' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     ghcr.io/upayanmazumder/gitorgasm/core@sha256:49cc0ad5c56dc7efbcabbe6982a7bf30fe3ca030e39929039ffa0ff0afb22232
   kubectl -n gitorgasm get deployments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}'
   ```

   The digest above is the output of signing run `42061786149`; a successful signing job alone is not an independent verification result.
3. Use read-only server-side dry-run admission (`kubectl run ... --dry-run=server -o yaml`) for that signed index and a separately verified unsigned, existing digest of the same repository. In `gitorgasm`, the positive case must validate without a failed-policy warning; the negative case must be admitted **with** a failed-policy warning. Check controller logs for the corresponding policy result so a fail-open webhook outage cannot masquerade as success. Run the unsigned case in an unselected test namespace and a Postgres case in gitorgasm: neither must produce this policy's warning. These commands must use existing namespaces and must not create live pods.

   Concrete controls (server-side dry-run only; run after the controller is healthy):

   ```bash
   kubectl -n gitorgasm run signature-positive --restart=Never --dry-run=server -o yaml \
     --image=ghcr.io/upayanmazumder/gitorgasm/core@sha256:49cc0ad5c56dc7efbcabbe6982a7bf30fe3ca030e39929039ffa0ff0afb22232
   kubectl -n gitorgasm run signature-negative --restart=Never --dry-run=server -o yaml \
     --image=ghcr.io/upayanmazumder/gitorgasm/core@sha256:7410b54ac65caa9dc0ce7298fecf2d8b2dc58975c29f18c97c7ffb21630e18c9
   ```

4. Open a second PR changing `mode: warn` to `enforce` and workload `failurePolicy: Ignore` to `Fail` together, only after the preceding evidence is recorded. After it deploys, repeat server-side dry-runs: signed index admitted; unsigned same-repository digest rejected; Postgres and unselected namespaces unaffected. Record exact warnings/rejections and the tested digests in the changelog. Never infer denial from a successful render or from cosign verification alone.

## Alternatives rejected

- **CI-only verification:** does not protect the admission boundary or later manual image changes.
- **Kyverno/Cosign policies:** useful for a broader policy programme but adds another general-purpose engine for this single Sigstore requirement. The dedicated controller is the narrower fit.
- **Cluster-wide opt-in or enforcement:** expands outage risk and would deny unrelated unsigned workloads. Only gitorgasm is authorized here.
- **Immediate enforcement:** could block existing unsigned images or a wrong identity/bundle format. The warning phase is an explicit migration gate, not the final security posture.
- **Pin chart 0.10.8 without a controller override:** leaves OCI referrer/cosign v3 compatibility behind the signing workflow.

## Consequences and rollback

The cluster gains a namespace-scoped provenance check without changing tenant manifest ownership. Admission now depends on GHCR signature discovery and public Sigstore trust-root services. The controller has upstream cluster-scoped read permissions (including Secret/ServiceAccount reads for registry authentication); namespace scope limits webhook admission reach, not its RBAC. The controller creates its own serving-certificate Secret at runtime; no plaintext credentials are committed.

Warn mode remains fail-open by design. Enforced fail-closed operation later makes gitorgasm availability depend on this one replica and external verification services; it still cannot block other namespaces or its own recovery. Registry/authentication or TUF failures must be diagnosed rather than bypassed with insecure flags. Review measured resources after rollout.

Rollback promotion by reverting its GitOps commit, restoring **both** warn and Ignore. To remove the installation, first revert policy enforcement, then remove the policies Application before the controller; do not leave fail-closed webhooks pointing at a deleted Service. Keep CRDs/policy ownership in mind before removing an Application; do not delete unrelated policies or namespaces.

## Evidence and upstream references

- **2026-11-05 independent signature verification:** coordinating agent `Main` reports successful `cosign verify` using container `ghcr.io/sigstore/cosign/cosign:v3.1.4` for index `sha256:49cc0ad5c56dc7efbcabbe6982a7bf30fe3ca030e39929039ffa0ff0afb22232`, with exactly the issuer and reusable-workflow SAN specified above. Claims validation, offline transparency-log inclusion and code-signing certificate checks passed. This confirms the configured signer identity; it does not establish that the not-yet-deployed admission controller accepts the bundle. Controller health and positive/negative admission remain separate promotion gates.
- **2026-11-05 unsigned negative control:** `Main` confirmed existing core index `sha256:7410b54ac65caa9dc0ce7298fecf2d8b2dc58975c29f18c97c7ffb21630e18c9` from publish run `42058299719`. Exact-identity/issuer cosign verification failed with **no signatures found**, exit **10**. Use that existing image for negative server-dry-run admission, not a nonexistent digest whose registry lookup failure could obscure policy behavior.
- [`policy-controller` Application](../../k8s/argocd/applications/platform/policy-controller.yaml), [values](../../k8s/platform/policy-controller/values.yaml), and [policy Application](../../k8s/argocd/applications/platform/policy-controller-policies.yaml).
- [Signature policy](../../k8s/platform/policy-controller-policies/gitorgasm-core.yaml) and [platform permissions](../../k8s/argocd/projects/platform.yaml).
- [`check-image-policy.py`](../../scripts/check-image-policy.py) validates the rendered scope, exact identity, rollout pairing, node/image pins, and policy against the **rendered chart CRD**, without `ignore-missing-schemas` for that custom resource. The regular render/schema job also covers the installed chart. Offline checks do not prove live admission.
- [Pinned chart values](https://github.com/sigstore/helm-charts/blob/policy-controller-0.10.8/charts/policy-controller/values.yaml), [v0.14 release](https://github.com/sigstore/policy-controller/releases/tag/v0.14.0), [v0.15 release](https://github.com/sigstore/policy-controller/releases/tag/v0.15.0), and [v0.15.1 release](https://github.com/sigstore/policy-controller/releases/tag/v0.15.1).
- [Fulcio GitHub OIDC identity mapping](https://github.com/sigstore/fulcio/blob/main/docs/oidc.md), [signing workflow](https://github.com/upayanmazumder/gitorgasm/blob/main/.github/workflows/image-publish.yml), and [successful publish run](https://github.com/upayanmazumder/gitorgasm/actions/runs/42061786149).
