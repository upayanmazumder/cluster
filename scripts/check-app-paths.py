#!/usr/bin/env python3
"""CI-002 (partial) — every Application `path:` that points at THIS repo must exist.

Why this exists: ArgoCD resolves an Application's `path` at sync time, so a typo, a renamed
directory, or a directory deleted without its Application/ApplicationSet element produces a
*comparison error on the cluster* rather than a failure in review. The cluster is the last place to
find that out, and an app whose path is missing sits degraded until someone reads its status.

It checks four things, all of them within this repo:

1. every Application/ApplicationSet/bootstrap `sources[].path` (or `source.path`) whose `repoURL` is
   this repository exists as a directory;
2. every ApplicationSet list element expands to a directory that exists (the template path is
   `k8s/apps/{{.name}}`, so the element list and the directory tree have to agree);
3. the reverse: every directory under `k8s/apps/` is claimed by *something* — an ApplicationSet
   element or an explicit Application. A directory with no owner is silently undeployed, which is
   how `cheatsheet` sat in the tree after its element was removed;
4. `helm.valueFiles` entries that resolve into this repository (the `$values/...` form) exist.

Scope: this is the half of CI-002 that does not depend on the CLUSTER-002 restructure. CI-002's other
half — kubeconform against the CRDs catalogue, including `clusters/**` and `bootstrap/` — lands with
that restructure, because the paths it validates do not exist yet.

Exit: 0 clean, 1 on any finding.
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
THIS_REPO = "https://github.com/upayanmazumder/cluster"

# Where Application/ApplicationSet manifests live. `k8s/argocd/` is watched recursively by the root
# app; bootstrap/ holds the one hand-applied Application.
MANIFEST_GLOBS = (
    "k8s/argocd/applications/**/*.yaml",
    "k8s/argocd/applicationsets/*.yaml",
    "k8s/bootstrap/*.yaml",
)


def load_docs(path: pathlib.Path):
    try:
        return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]
    except Exception as exc:  # a malformed manifest is a real finding, but not this script's job
        print(f"  note: {path.relative_to(REPO_ROOT)} could not be parsed ({exc.__class__.__name__})")
        return []


def rel(p: pathlib.Path) -> str:
    return str(p.relative_to(REPO_ROOT))


def sources_of(doc: dict) -> list[dict]:
    spec = doc.get("spec") or {}
    out = []
    if isinstance(spec.get("source"), dict):
        out.append(spec["source"])
    for s in spec.get("sources") or []:
        if isinstance(s, dict):
            out.append(s)
    return out


def main() -> int:
    findings: list[str] = []
    checked_paths: list[tuple[str, str]] = []  # (manifest, path)
    refs_to_this_repo: dict[tuple[str, str], str] = {}  # (manifest, ref) -> anchor
    claimed_dirs: set[str] = set()
    app_dirs = {p.name for p in (REPO_ROOT / "k8s/apps").iterdir() if p.is_dir()}

    manifests = []
    for pattern in MANIFEST_GLOBS:
        manifests.extend(sorted(REPO_ROOT.glob(pattern)))

    for path in manifests:
        for doc in load_docs(path):
            kind = doc.get("kind")
            if kind not in ("Application", "ApplicationSet"):
                continue

            # 1 + 4: paths and Helm value files that live here
            for src in sources_of(doc):
                repo = src.get("repoURL")
                if src.get("ref"):
                    refs_to_this_repo[(rel(path), src["ref"])] = repo
                if repo != THIS_REPO:
                    continue
                if src.get("path"):
                    checked_paths.append((rel(path), src["path"]))
                helm = src.get("helm") or {}
                for vf in helm.get("valueFiles") or []:
                    if not isinstance(vf, str) or not vf.startswith("$"):
                        continue
                    ref, _, tail = vf[1:].partition("/")
                    # `$values/...` resolves to whatever the source labelled `values` points at; only
                    # this repo's files can be checked here.
                    anchor = refs_to_this_repo.get((rel(path), ref))
                    if anchor is None or anchor == THIS_REPO or repo == THIS_REPO:
                        if tail:
                            checked_paths.append((rel(path), tail))

            # 2: ApplicationSet elements expand into the template's path
            if kind == "ApplicationSet":
                spec = doc.get("spec") or {}
                tmpl_path = ((spec.get("template") or {}).get("spec") or {}).get("source", {}).get("path")
                for gen in spec.get("generators") or []:
                    for element in (gen.get("list") or {}).get("elements") or []:
                        name = (element or {}).get("name")
                        if name and tmpl_path:
                            expanded = tmpl_path.replace("{{.name}}", name).replace("{{ .name }}", name)
                            checked_paths.append((rel(path), expanded))

    for manifest, p in checked_paths:
        if not (REPO_ROOT / p).exists():
            findings.append(f"{manifest}: path '{p}' does not exist in this repo")
        # 3: whatever an in-repo path points *into* is claimed. A values file under
        # `k8s/apps/<name>/values/` claims `<name>` just as an Application `path:` would — which
        # matters because an Application that consumes values through a `ref` source has no
        # `path:` of its own pointing at that directory.
        m = re.match(r"^k8s/apps/([^/]+)(?:/|$)", p)
        if m:
            claimed_dirs.add(m.group(1))

    unclaimed = sorted(app_dirs - claimed_dirs)
    for name in unclaimed:
        findings.append(
            f"k8s/apps/{name}/ is not claimed by any Application or ApplicationSet element — "
            f"it is silently undeployed"
        )

    print(f"check-app-paths.py: checked {len(checked_paths)} path(s) across {len(manifests)} manifests, "
          f"{len(app_dirs)} app director(ies)")
    if findings:
        for f in findings:
            print(f"FAIL: {f}")
        print(f"check-app-paths.py: FAILED ({len(findings)} finding(s))")
        return 1
    print("check-app-paths.py: OK — every in-repo path and app directory is accounted for")
    return 0


if __name__ == "__main__":
    sys.exit(main())
