# 0010 — Verify gitorgasm publication attestations with a namespace-scoped Sigstore controller

**Status:** Accepted, partially implemented (installed; corrective attestation policy remains warning-only)
**Date:** 2026-11-05

## Context

PR #84 installed Sigstore policy-controller in warning mode. The first live smoke found that v0.15.1 cannot verify cosign v3 image-signature bundles: signed and unsigned images both warned. The gitorgasm repository owns its Namespace/workloads and publishes signed artifacts; this repository owns platform admission controls. Other namespaces and gitorgasm's Postgres image must remain unaffected.

## Decision

Keep chart **0.10.8** and controller **v0.15.1**, pinned at `sha256:0492bb264fb1d9bdc8e3f343ef542cc85b7dd7c7fd8d9524b453c2bd31a1d128`. The controller supports cryptographic **attestation** bundle verification, not bundle image-signature verification. Its v1beta1 CRD supports the required attestation/CUE fields. The cleanup image remains digest-pinned.

Both workload webhooks select **only** namespaces whose API-server-managed `kubernetes.io/metadata.name` is `gitorgasm`. This avoids a tenant-controlled opt-in label and excludes `policy-controller`, `kube-system`, `argocd`, monitoring, and every other tenant. The `ClusterImagePolicy` matches only the exact repository `ghcr.io/upayanmazumder/gitorgasm/core` (tag or digest references, not repositories beginning with `core`). Images without a matching policy are allowed, so Postgres is not accidentally denied by the upstream default.

Require a cryptographically verified Sigstore **attestation bundle**, public-good Sigstore trust material from TUF, and the exact certificate identity:

- OIDC issuer: `https://token.actions.githubusercontent.com`
- SAN subject: `https://github.com/upayanmazumder/gitorgasm/.github/workflows/image-publish.yml@refs/heads/main`

The SAN is the reusable signing workflow (`job_workflow_ref`), not caller `ci.yml`, an environment name, or arbitrary repository workflow. Do not broaden it to a regular expression.

Require predicate type `https://gitorgasm.upayan.dev/attestations/image-publish/v1` with CUE checking `predicate.repository: "upayanmazumder/gitorgasm"` and `predicate.ref: "refs/heads/main"`. The workflow adds this signed publication attestation without removing its existing image signature. Its JSON records repository, commit, ref and digest: a publication event, **not** SLSA build provenance or an SBOM.

Explicitly set `enable-oci11: "false"`. The controller's experimental discovery shortcut parses DSSE without invoking cosign verification. Normal attestation-bundle verification already discovers referrers and verifies the DSSE signature, exact SAN/issuer, subject digest and certificate/transparency trust. CI forbids enabling the shortcut or removing attestation/CUE constraints.

Both selectors also explicitly include `webhooks.knative.dev/exclude DoesNotExist`, matching the controller-injected selector observed live. Keep `metadata.name In [gitorgasm]` alongside it; do not ignore selector drift.

Begin with `spec.mode: warn` and workload `failurePolicy: Ignore`. Failed signatures warn rather than prevent restarts, and controller outages cannot block gitorgasm during observation. The policy-object admission webhooks remain upstream fail-closed; they only handle policy/trust-root writes, not application workloads. No warning-only rollout is represented as enforcement.

Use one controller replica on node `vps`, requests 50m CPU/128Mi, limits 250m/384Mi, and no single-replica disruption budget. These are configured budgets, not measured consumption. The namespace uses the shared Pod Security baseline. A separate policies Application retries bootstrap while CRDs and the webhook become available. Server-side apply avoids CRD annotation-size limits. ArgoCD ignores only controller-generated certificate/rule/config data; namespace selectors and failure policies remain reconciled.

## Promotion gates and live validation

The installation is merged; its failed initial smoke stopped promotion. The corrective policy stays warn/Ignore. All persistent changes go through reviewed GitOps PRs.

1. Confirm both Applications are Synced/Healthy, controller Available and policy Ready. Confirm both exact namespace selectors and the `policy-controller` Service namespace.
2. Set `ATTESTED_IMAGE` to the exact index output from the updated publish workflow. Independently verify its publication attestation, and confirm api/worker workload specs use that index, not a tag or runtime platform-specific child imageID.

   ```bash
   cosign verify-attestation \
     --type https://gitorgasm.upayan.dev/attestations/image-publish/v1 \
     --certificate-identity 'https://github.com/upayanmazumder/gitorgasm/.github/workflows/image-publish.yml@refs/heads/main' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     "$ATTESTED_IMAGE"
   kubectl -n gitorgasm get deployments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}'
   ```

   Earlier image-signature verification alone does not satisfy this attestation gate.
3. In gitorgasm, the attested positive must have no failed-policy warning; unsigned and wrong-identity controls must warn. Inspect corresponding controller validation results to rule out fail-open bypass. Postgres and the unsigned control in an unselected existing namespace must have no warning from this policy. Use server-side dry-run only, without creating live pods.

   Concrete controls (server-side dry-run only; run after the controller is healthy):

   ```bash
   kubectl -n gitorgasm run signature-positive --restart=Never --dry-run=server -o yaml \
     --image="$ATTESTED_IMAGE"
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
- **2026-11-05 first smoke failed:** `Main` reports healthy/Ready controller, but signed and unsigned controls both warned `bundle support for image signatures is not yet implemented`. This invalidated the original assumption and halted enforcement. The correction requires a publication attestation; corrected live admission is not yet proven.
- Source: [controller attestation dispatch/experimental shortcut](https://github.com/sigstore/policy-controller/blob/v0.15.1/pkg/webhook/validation.go), [authority predicate evaluation](https://github.com/sigstore/policy-controller/blob/v0.15.1/pkg/webhook/validator.go), [normal cosign bundle verifier](https://github.com/sigstore/cosign/blob/v3.0.5/pkg/cosign/verify.go). The normal path calls `VerifyNewBundle` with artifact-digest policy and the in-toto subject verifier.
- [`policy-controller` Application](../../k8s/argocd/applications/platform/policy-controller.yaml), [values](../../k8s/platform/policy-controller/values.yaml), and [policy Application](../../k8s/argocd/applications/platform/policy-controller-policies.yaml).
- [Signature policy](../../k8s/platform/policy-controller-policies/gitorgasm-core.yaml) and [platform permissions](../../k8s/argocd/projects/platform.yaml).
- [`check-image-policy.py`](../../scripts/check-image-policy.py) validates the rendered scope, exact identity, rollout pairing, node/image pins, and policy against the **rendered chart CRD**, without `ignore-missing-schemas` for that custom resource. The regular render/schema job also covers the installed chart. Offline checks do not prove live admission.
- [Pinned chart values](https://github.com/sigstore/helm-charts/blob/policy-controller-0.10.8/charts/policy-controller/values.yaml), [v0.14 release](https://github.com/sigstore/policy-controller/releases/tag/v0.14.0), [v0.15 release](https://github.com/sigstore/policy-controller/releases/tag/v0.15.0), and [v0.15.1 release](https://github.com/sigstore/policy-controller/releases/tag/v0.15.1).
- [Fulcio GitHub OIDC identity mapping](https://github.com/sigstore/fulcio/blob/main/docs/oidc.md), [signing workflow](https://github.com/upayanmazumder/gitorgasm/blob/main/.github/workflows/image-publish.yml), and [successful publish run](https://github.com/upayanmazumder/gitorgasm/actions/runs/42061786149).
