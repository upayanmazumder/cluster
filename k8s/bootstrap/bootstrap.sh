#!/usr/bin/env bash
# P4-04: bootstrap ArgoCD on a brand-new cluster (DR-005).
#
# On a fresh node the cluster has an API server and nothing else. ArgoCD cannot be left to a
# `kubectl apply -f k8s/bootstrap/root-app.yaml` alone, because:
#   1. ArgoCD needs its repo credentials *before* it can fetch anything, and those credentials live
#      SOPS-encrypted inside the repository it is trying to fetch. (This said "the app-of-apps repo
#      is private", which was the reason when it was written and is no longer true —
#      `upayanmazumder/cluster` is public. The chicken-and-egg survives the change of visibility:
#      step 3 also installs the *tenant* repo credentials and the image-updater's write-back key,
#      and `configs.secret.createSecret: false` means `argocd-secret` itself — the admin hash and
#      `server.secretkey` — comes from the same SOPS file. A public source repo removes one of the
#      reasons for this step, not the step.)
#   2. ksops needs the age-cluster key, which is (correctly) never in git;
#   3. ArgoCD itself is installed by Helm and afterwards adopted by its self-managed Application.
#
# This script performs exactly that order. It is deliberately imperative and one-shot: it is not a
# reconciler, and re-running it is safe but not the normal path (ArgoCD owns everything after step 7).
#
# No secret is hard-coded or committed. The one secret it needs — the age-cluster private key — is
# read from a file the operator exports from the password manager, and the script refuses to run
# without it rather than half-bootstrapping a cluster it cannot decrypt.
#
# Usage:
#   export AGE_CLUSTER_KEYS_FILE=/dev/shm/age-cluster/keys.txt   # from the password manager (P4-01)
#   k8s/bootstrap/bootstrap.sh
#
# Exit: 0 the cluster is managed by ArgoCD; non-zero before anything was applied (missing key/tool),
# or a step failed.
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# Preflight: fail closed BEFORE touching the cluster.
# ---------------------------------------------------------------------------------------------
: "${AGE_CLUSTER_KEYS_FILE:?set AGE_CLUSTER_KEYS_FILE to the age-cluster keys.txt exported from the password manager (P4-01)}"

if [ ! -r "$AGE_CLUSTER_KEYS_FILE" ]; then
  echo "fatal: age-cluster key file '$AGE_CLUSTER_KEYS_FILE' does not exist or is not readable." >&2
  echo "       Export it from the password manager first; without it the SOPS secrets cannot be" >&2
  echo "       decrypted and the bootstrap would leave a cluster ArgoCD can never take over." >&2
  exit 1
fi

for tool in kubectl helm sops; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "fatal: '$tool' is not installed (or not on PATH)." >&2
    exit 1
  fi
done

# The script lives at k8s/bootstrap/bootstrap.sh, so the repo root is two levels up.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

argocd_values="k8s/platform/argocd/values.yaml"
argocd_secrets="k8s/platform/argocd/secret/secrets.sops.yaml"
root_app="k8s/bootstrap/root-app.yaml"
for f in "$argocd_values" "$argocd_secrets" "$root_app"; do
  if [ ! -f "$f" ]; then
    echo "fatal: '$f' is missing — is this the repository root?" >&2
    exit 1
  fi
done

echo "bootstrap: repo=$repo_root age key=$AGE_CLUSTER_KEYS_FILE"

# ---------------------------------------------------------------------------------------------
# 1. The namespace ArgoCD lives in.
# ---------------------------------------------------------------------------------------------
echo "bootstrap: ensuring namespace argocd"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------------------------
# 2. The age-cluster key Secret, read from the operator's exported key file.
#    The value comes from $AGE_CLUSTER_KEYS_FILE, never from this script or the repo.
# ---------------------------------------------------------------------------------------------
echo "bootstrap: installing the sops-age Secret from $AGE_CLUSTER_KEYS_FILE"
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt="$AGE_CLUSTER_KEYS_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------------------------
# 3. The repo credentials and other ArgoCD Secrets, SOPS-encrypted in the repo ArgoCD cannot yet
#    fetch. This is the step whose absence shows up as
#    "ComparisonError: failed to get git client for repo https://github.com/upayanmazumder/cluster".
# ---------------------------------------------------------------------------------------------
echo "bootstrap: applying the ArgoCD repo credentials (SOPS: $argocd_secrets)"
SOPS_AGE_KEY_FILE="$AGE_CLUSTER_KEYS_FILE" \
  sops -d "$argocd_secrets" | kubectl apply -f -

# ---------------------------------------------------------------------------------------------
# 4. ArgoCD itself, at the pinned chart version the live cluster runs.
# ---------------------------------------------------------------------------------------------
echo "bootstrap: adding the argo Helm repository"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null

echo "bootstrap: installing ArgoCD (chart 7.9.1)"
helm upgrade --install argocd argo/argo-cd --version 7.9.1 -n argocd -f "$argocd_values"

# ---------------------------------------------------------------------------------------------
# 5. Wait for the component that does the SOPS/ksops rendering, so the root app's first sync does
#    not race it.
# ---------------------------------------------------------------------------------------------
echo "bootstrap: waiting for argocd-repo-server"
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=5m

# ---------------------------------------------------------------------------------------------
# 6. Hand control over: the app-of-apps reads k8s/argocd/ recursively and creates every other
#    Application, including ArgoCD's own self-management.
# ---------------------------------------------------------------------------------------------
echo "bootstrap: applying the app-of-apps root"
kubectl apply -f "$root_app"

echo "bootstrap: done — 'kubectl -n argocd get applications' should populate over the next few minutes"
