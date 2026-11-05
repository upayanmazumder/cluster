#!/usr/bin/env python3
"""Validate the rendered Sigstore rollout and its policy against the chart's actual CRD.

Usage: python3 scripts/check-image-policy.py HELM_RENDER KUSTOMIZE_RENDER
Requires PyYAML and kubeconform, already used by the manifest validation job.
This checks configuration/schema, not registry signatures or live admission.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

ROOT = Path(__file__).resolve().parent.parent
IMAGE = "ghcr.io/upayanmazumder/gitorgasm/core"
CONTROLLER = (
    "ghcr.io/sigstore/policy-controller/policy-controller@sha256:"
    "0492bb264fb1d9bdc8e3f343ef542cc85b7dd7c7fd8d9524b453c2bd31a1d128"
)
SUBJECT = (
    "https://github.com/upayanmazumder/gitorgasm/"
    ".github/workflows/image-publish.yml@refs/heads/main"
)
SELECTOR = {"matchExpressions": [
    {"key": "webhooks.knative.dev/exclude", "operator": "DoesNotExist"},
    {"key": "kubernetes.io/metadata.name", "operator": "In", "values": ["gitorgasm"]},
]}
PREDICATE_TYPE = "https://gitorgasm.upayan.dev/attestations/image-publish/v1"
PUBLICATION_POLICY = (
    'predicate: {\n'
    '  repository: "upayanmazumder/gitorgasm"\n'
    '  ref: "refs/heads/main"\n'
    '}\n'
)


def documents(path: Path) -> list[dict]:
    return [doc for doc in yaml.safe_load_all(path.read_text()) if isinstance(doc, dict)]


def only(docs: list[dict], kind: str, name: str) -> dict:
    matches = [doc for doc in docs if doc.get("kind") == kind
               and doc.get("metadata", {}).get("name") == name]
    if len(matches) != 1:
        raise ValueError(f"expected one {kind}/{name}, found {len(matches)}")
    return matches[0]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def close_schema(schema: dict) -> None:
    """Reject unknown fields, while preserving CRD maps and explicitly free-form data."""
    if schema.get("properties") and not schema.get("x-kubernetes-preserve-unknown-fields"):
        schema.setdefault("additionalProperties", False)
    for value in schema.values():
        if isinstance(value, dict):
            close_schema(value)
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    close_schema(item)


def main() -> None:
    helm, rendered = (documents(Path(arg)) for arg in sys.argv[1:])
    policy = only(rendered, "ClusterImagePolicy", "gitorgasm-core-signed")
    spec = policy["spec"]
    require(spec["mode"] in ("warn", "enforce"), "policy must explicitly set warn or enforce")
    expected_failure = "Ignore" if spec["mode"] == "warn" else "Fail"
    for kind in ("MutatingWebhookConfiguration", "ValidatingWebhookConfiguration"):
        webhook = only(helm, kind, "policy.sigstore.dev")["webhooks"]
        require(len(webhook) == 1, f"unexpected {kind} webhook count")
        require(webhook[0]["namespaceSelector"] == SELECTOR, f"{kind} scope broadened")
        require(webhook[0]["failurePolicy"] == expected_failure, f"{kind} failurePolicy/mode mismatch")
        require(webhook[0]["clientConfig"]["service"]["namespace"] == "policy-controller",
                f"{kind} has the wrong service namespace")
        print(f"{kind}/policy.sigstore.dev: gitorgasm only, failurePolicy={expected_failure}")
    config = only(helm, "ConfigMap", "config-policy-controller")
    require(config["data"]["no-match-policy"] == "allow", "unmatched Postgres must remain allowed")
    require(config["data"].get("enable-oci11") == "false",
            "experimental OCI discovery must remain explicitly disabled; discovery is not verification")
    deployment = only(helm, "Deployment", "policy-controller-webhook")
    pod = deployment["spec"]["template"]["spec"]
    require(deployment["spec"]["replicas"] == 1, "expected single-node replica budget")
    require(pod["containers"][0]["image"] == CONTROLLER, "controller digest changed without validation update")
    require(pod["containers"][0]["resources"] == {
        "requests": {"cpu": "50m", "memory": "128Mi"},
        "limits": {"cpu": "250m", "memory": "384Mi"},
    }, "controller resource budget changed")
    expressions = pod["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"]
    require(expressions == [{"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": ["vps"]}]}],
            "controller must stay on vps")
    require(spec["images"] == [{"glob": IMAGE + "@sha256:*"}, {"glob": IMAGE + ":*"}],
            "policy must match the exact core repository, not a repository prefix")
    require(len(spec["authorities"]) == 1, "unexpected additional signature authority")
    authority = spec["authorities"][0]
    require(authority["signatureFormat"] == "bundle", "cosign v3 requires bundle format")
    require(authority["keyless"] == {
        "url": "https://fulcio.sigstore.dev",
        "identities": [{"issuer": "https://token.actions.githubusercontent.com", "subject": SUBJECT}],
    }, "keyless issuer/subject or trust bypass changed")
    require(authority["ctlog"] == {"url": "https://rekor.sigstore.dev"}, "transparency log configuration changed")
    require(authority.get("attestations") == [{
        "name": "image-publication",
        "predicateType": PREDICATE_TYPE,
        "policy": {"type": "cue", "data": PUBLICATION_POLICY},
    }], "require the supported bundle attestation path and exact publication predicate constraints")
    namespace = only(rendered, "Namespace", "policy-controller")
    require(namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "baseline",
            "controller namespace must use the namespace baseline")
    project = yaml.safe_load((ROOT / "k8s/argocd/projects/platform.yaml").read_text())["spec"]
    require("https://sigstore.github.io/helm-charts" in project["sourceRepos"], "chart repo not allowed")
    require({"server": "https://kubernetes.default.svc", "namespace": "policy-controller"} in project["destinations"],
            "controller destination not allowed")
    require({"group": "policy.sigstore.dev", "kind": "ClusterImagePolicy"} in project["clusterResourceWhitelist"],
            "ClusterImagePolicy not allowed by platform project")
    crd = only(helm, "CustomResourceDefinition", "clusterimagepolicies.policy.sigstore.dev")
    require(crd["spec"]["conversion"]["webhook"]["clientConfig"]["service"]["namespace"] == "policy-controller",
            "CRD conversion points outside the controller namespace")
    version = policy["apiVersion"].split("/")[1]
    schema = next(item["schema"]["openAPIV3Schema"] for item in crd["spec"]["versions"]
                  if item["name"] == version and item["served"])
    # CRDs may omit the Kubernetes resource envelope: the API server supplies
    # these fields implicitly. Add that envelope for standalone JSON Schema.
    schema["properties"].update({
        "apiVersion": {"type": "string"},
        "kind": {"type": "string"},
        "metadata": {"type": "object"},
    })
    close_schema(schema)
    with tempfile.TemporaryDirectory(prefix="image-policy-schema-") as directory:
        schema_path = Path(directory) / "policy.json"
        policy_path = Path(directory) / "policy.yaml"
        schema_path.write_text(json.dumps(schema))
        policy_path.write_text(yaml.safe_dump(policy))
        subprocess.run(["kubeconform", "-strict", "-summary", "-schema-location", str(schema_path),
                        str(policy_path)], check=True)
    print(f"ClusterImagePolicy/gitorgasm-core-signed: mode={spec['mode']}, exact issuer/subject, signed publication attestation")
    print(f"Controller: {CONTROLLER}")
    print("check-image-policy.py: OK — shipped CRD + scope, identity, attestation/CUE, experimental-discovery guard, mode and budget")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: check-image-policy.py HELM_RENDER KUSTOMIZE_RENDER")
    try:
        main()
    except (ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as exc:
        sys.exit(f"check-image-policy.py: FAILED: {exc}")
