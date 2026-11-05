# 0010 — Verify gitorgasm publication attestations with a namespace-scoped Sigstore controller

**Status:** Accepted (enforce/Fail configured after successful corrected warning-mode verification)
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

Set `spec.mode: enforce` and workload `failurePolicy: Fail` together. Missing or invalid publication attestations are rejected; webhook unavailability cannot bypass verification. This promotion follows successful corrected warning-mode controls recorded below. Policy-object webhooks also remain fail-closed.

Use one controller replica on node `vps`, requests 50m CPU/128Mi, limits 250m/384Mi, and no single-replica disruption budget. These are configured budgets, not measured consumption. The namespace uses the shared Pod Security baseline. A separate policies Application retries bootstrap while CRDs and the webhook become available. Server-side apply avoids CRD annotation-size limits. ArgoCD ignores only controller-generated certificate/rule/config data; namespace selectors and failure policies remain reconciled.

## Verified promotion and recurring admission checks

PR #85 corrected bundle verification and both Applications are Synced/Healthy with the policy Ready. `Main` independently verified the publication attestation for run `42072655836`, job `127407321212`, index `sha256:781672f7fdd17a459770e7a4937b06823fffb467318bdb68f5fa7be2acbfb6cd`; api/worker specs use that index. Warning-mode live positive admission had no policy warning; unsigned admission warned `no valid bundles exist in registry`; Postgres and the unsigned image in `default` had no policy warnings. Controller logs correlated the positive/negative requests.

The wrong-identity check independently failed cosign verification when expecting caller `ci.yml` instead of actual `image-publish.yml`. This is certificate-verifier negative evidence, **not** a live wrong-signer admission test.

### Final enforced admission evidence (2026-11-05)

After PR #86 merged, `Main` verified both controller Applications **Synced/Healthy** and completed live server-side dry-runs under enforce/Fail:

| Control | Observed enforced result |
|---|---|
| Attested core index `sha256:781672f7fdd17a459770e7a4937b06823fffb467318bdb68f5fa7be2acbfb6cd` in gitorgasm | Admitted |
| Existing unsigned core index `sha256:7410b54ac65caa9dc0ce7298fecf2d8b2dc58975c29f18c97c7ffb21630e18c9` in gitorgasm | Denied; failure reason contains `no valid bundles` |
| Postgres in gitorgasm | Admitted; no publication-attestation requirement |
| Unsigned core in default namespace | Admitted; outside webhook namespace scope |

The independent wrong-identity cosign failure above is not relabeled as a live wrong-signer test. These results establish actual enforced unsigned rejection, not merely desired configuration or warning-mode behavior.


Repeat these checks after enforcement sync and on verifier upgrades:

1. Confirm both Applications Synced/Healthy, policy Ready, exact namespace selectors and failurePolicy Fail.
2. Verify the attestation and confirm api/worker workload-spec digests:

   ```bash
   cosign verify-attestation \
     --type https://gitorgasm.upayan.dev/attestations/image-publish/v1 \
     --certificate-identity 'https://github.com/upayanmazumder/gitorgasm/.github/workflows/image-publish.yml@refs/heads/main' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     ghcr.io/upayanmazumder/gitorgasm/core@sha256:781672f7fdd17a459770e7a4937b06823fffb467318bdb68f5fa7be2acbfb6cd
   kubectl -n gitorgasm get deployments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}'
   ```

   Standalone image-signature verification is not a substitute for this attestation check.
3. Use server-side dry-runs only: attested positive must be admitted without policy warnings; unsigned core must be **rejected** under enforcement. Postgres and the unsigned control in `default` remain admitted without this policy's warning. Confirm matching controller results; do not infer rejection from a successful render.

   Concrete controls (server-side dry-run only; run after the controller is healthy):

   ```bash
   kubectl -n gitorgasm run signature-positive --restart=Never --dry-run=server -o yaml \
     --image=ghcr.io/upayanmazumder/gitorgasm/core@sha256:781672f7fdd17a459770e7a4937b06823fffb467318bdb68f5fa7be2acbfb6cd
   kubectl -n gitorgasm run signature-negative --restart=Never --dry-run=server -o yaml \
     --image=ghcr.io/upayanmazumder/gitorgasm/core@sha256:7410b54ac65caa9dc0ce7298fecf2d8b2dc58975c29f18c97c7ffb21630e18c9
   ```

Post-merge signed admission and unsigned rejection are now verified as recorded above. Repeat the same controls after verifier/policy upgrades, retaining exact digests and admission outputs in the changelog.

## Alternatives rejected

- **CI-only verification:** does not protect the admission boundary or later manual image changes.
- **Kyverno/Cosign policies:** useful for a broader policy programme but adds another general-purpose engine for this single Sigstore requirement. The dedicated controller is the narrower fit.
- **Cluster-wide opt-in or enforcement:** expands outage risk and would deny unrelated unsigned workloads. Only gitorgasm is authorized here.
- **Immediate enforcement:** could block existing unsigned images or a wrong identity/bundle format. The warning phase is an explicit migration gate, not the final security posture.
- **Pin chart 0.10.8 without a controller override:** leaves OCI referrer/cosign v3 compatibility behind the signing workflow.

## Consequences and rollback

The cluster gains a namespace-scoped provenance check without changing tenant manifest ownership. Admission now depends on GHCR signature discovery and public Sigstore trust-root services. The controller has upstream cluster-scoped read permissions (including Secret/ServiceAccount reads for registry authentication); namespace scope limits webhook admission reach, not its RBAC. The controller creates its own serving-certificate Secret at runtime; no plaintext credentials are committed.

Fail-closed operation makes gitorgasm admission depend on this replica and external verification services; it cannot block other namespaces or the controller's own recovery. Registry/authentication or TUF failures must be diagnosed, not bypassed with insecure flags. Review measured resources after rollout.

The mutator normalizes **all** container images in the selected namespace before policy matching, including unmatched Postgres. On 2026-11-05 this caused own-induced ArgoCD drift: tenant desired `postgres:18.6-alpine`, live StatefulSet `index.docker.io/library/postgres:18.6-alpine@sha256:10a5c69a83035ab5239f5620d708520e8b28f5aa1f2b20143e6024532edadfb5`. The application was Healthy/OutOfSync and repeatedly reapplied Postgres (seven auto-heal attempts observed). The database remained Ready.

Do not disable the mutator as a workaround: the validator requires digest references for every container before checking no-match allowance; it does not independently resolve tag-only references. The safe fix is to pin the tenant's desired Postgres image to the same fully qualified live tag/digest.

**Resolved:** [tenant PR #76](https://github.com/upayanmazumder/gitorgasm/pull/76) merged as `5f2697041d7aa601c9ce06a17a9287ac6719eda8`. `Main` independently verified the registry digest, confirmed desired and live Postgres references match the canonical tag/digest above, and observed gitorgasm at that revision **Synced/Healthy** via kubectl wait. The pin preserves the already-running image digest and database data. Both controller Applications are also Synced/Healthy. No object-label bypass, ignored image drift, admission relaxation, or manual cluster mutation was needed.

Rollback promotion by reverting its GitOps commit, restoring **both** warn and Ignore. To remove the installation, first revert policy enforcement, then remove the policies Application before the controller; do not leave fail-closed webhooks pointing at a deleted Service. Keep CRDs/policy ownership in mind before removing an Application; do not delete unrelated policies or namespaces.

## Evidence and upstream references

- **2026-11-05 earlier image-signature verification:** `Main` successfully verified index `sha256:49cc0ad5c56dc7efbcabbe6982a7bf30fe3ca030e39929039ffa0ff0afb22232` with cosign v3.1.4 and exact issuer/SAN. That established the signer identity but was insufficient for admission: the subsequent unsupported-bundle failure required the attestation correction. Current promotion relies on the corrected attestation and live controls above.
- **2026-11-05 unsigned negative control:** `Main` confirmed existing core index `sha256:7410b54ac65caa9dc0ce7298fecf2d8b2dc58975c29f18c97c7ffb21630e18c9` from publish run `42058299719`. Exact-identity/issuer cosign verification failed with **no signatures found**, exit **10**. Use that existing image for negative server-dry-run admission, not a nonexistent digest whose registry lookup failure could obscure policy behavior.
- **2026-11-05 first smoke failed, subsequently corrected:** the healthy/Ready controller warned `bundle support for image signatures is not yet implemented` for both image-signature controls. PR #85 switched to cryptographic publication attestations. The successful corrected warning-mode evidence above is the basis for enforcement, not the initial failed smoke.
- Source: [controller attestation dispatch/experimental shortcut](https://github.com/sigstore/policy-controller/blob/v0.15.1/pkg/webhook/validation.go), [authority predicate evaluation](https://github.com/sigstore/policy-controller/blob/v0.15.1/pkg/webhook/validator.go), [normal cosign bundle verifier](https://github.com/sigstore/cosign/blob/v3.0.5/pkg/cosign/verify.go). The normal path calls `VerifyNewBundle` with artifact-digest policy and the in-toto subject verifier.
- [`policy-controller` Application](../../k8s/argocd/applications/platform/policy-controller.yaml), [values](../../k8s/platform/policy-controller/values.yaml), and [policy Application](../../k8s/argocd/applications/platform/policy-controller-policies.yaml).
- [Signature policy](../../k8s/platform/policy-controller-policies/gitorgasm-core.yaml) and [platform permissions](../../k8s/argocd/projects/platform.yaml).
- [`check-image-policy.py`](../../scripts/check-image-policy.py) validates the rendered scope, exact identity, rollout pairing, node/image pins, and policy against the **rendered chart CRD**, without `ignore-missing-schemas` for that custom resource. The regular render/schema job also covers the installed chart. Offline checks do not prove live admission.
- [Pinned chart values](https://github.com/sigstore/helm-charts/blob/policy-controller-0.10.8/charts/policy-controller/values.yaml), [v0.14 release](https://github.com/sigstore/policy-controller/releases/tag/v0.14.0), [v0.15 release](https://github.com/sigstore/policy-controller/releases/tag/v0.15.0), and [v0.15.1 release](https://github.com/sigstore/policy-controller/releases/tag/v0.15.1).
- [Fulcio GitHub OIDC identity mapping](https://github.com/sigstore/fulcio/blob/main/docs/oidc.md), [signing workflow](https://github.com/upayanmazumder/gitorgasm/blob/main/.github/workflows/image-publish.yml), and [successful publish run](https://github.com/upayanmazumder/gitorgasm/actions/runs/42061786149).
