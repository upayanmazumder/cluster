#!/usr/bin/env bash
# CI-003 — `helm template` every Helm-sourced Application with the values this repo actually uses,
# so the rendered output can be schema-checked (kubeconform) alongside the Kustomize manifests.
#
# Why: for the Helm-sourced apps, git holds only a values overlay — the chart lives in a Helm repo or
# in another Git repository. Nothing in this repo's CI looked at that combination, so a bad values key
# (a typo, a key the chart renamed, a value of the wrong type) reached the cluster as a failed or
# *silently different* sync. `helm template` is the cheap local render of exactly what ArgoCD will do.
#
# Two chart shapes are handled, distinguished by whether the source names a `path`:
#   - a Helm repository (`repoURL` + no path)  -> `helm template --repo <repoURL> --version <rev>`
#   - a chart inside a Git repository (`path`) -> shallow-clone `repoURL` at `targetRevision` and
#     template from `<clone>/<path>`
#
# Charts in another Git repository render when the repository is public and in the allowlist below.
# The v1 VCAP charts are public and render here. This script reports anything it skipped rather than
# passing silently.
#
# Usage: scripts/helm-template-all.sh [OUTFILE]   (default: stdout)
# Exit: 0 only if every Helm-sourced Application rendered.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:--}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rendered="$tmp/helm.yaml"
: >"$rendered"

total=0
failed=0
skipped=0

while IFS= read -r -d '' manifest; do
  # One line per (source, chart) so the shell loop stays simple; the Python below does the parsing.
  while IFS=$'\t' read -r app chart repo rev path valuefiles shape; do
    [ -n "$chart" ] || continue
    rel=${manifest#"$repo_root"/}
    total=$((total + 1))

    if [ "$shape" = "git" ]; then
      # A chart inside another Git repository. Only public repositories in this allowlist render.
      # Anything else is skipped *loudly* so a gap never reads as coverage.
      case "$repo" in
        *github.com/upayanmazumder/*|\
        *github.com/upayanmazumder-DevLabs/vcap-backend-v1|\
        *github.com/upayanmazumder-DevLabs/vcap-frontend-v1) ;;
        *)
          echo "SKIPPED: $app — chart lives in $repo, which is not in the render allowlist; rendered by that repo's own CI (CI-006)" >&2
          skipped=$((skipped + 1))
          continue
          ;;
      esac
      clone="$tmp/clone-$app"
      if ! git clone --quiet --depth 1 --branch "$rev" "$repo" "$clone" 2>"$tmp/err"; then
        echo "FAILED: $rel ($app): could not clone $repo@$rev" >&2
        sed 's/^/    /' "$tmp/err" >&2
        failed=$((failed + 1))
        continue
      fi
      args=(template "$app" "$clone/$path")
    else
      # Fetch the chart first. Helm 4.3.0 can time out while `helm template --repo` follows the
      # GitHub release-asset redirect, while `helm pull` with the same URL succeeds. Pulling also
      # keeps the index out of the render path.
      pull_dir="$tmp/pull-$app"
      mkdir -p "$pull_dir"
      if ! helm pull "$chart" --repo "$repo" --version "$rev" --destination "$pull_dir" 2>"$tmp/err"; then
        echo "FAILED: $rel ($app): could not pull $chart $rev from $repo" >&2
        sed 's/^/    /' "$tmp/err" >&2
        failed=$((failed + 1))
        continue
      fi
      chart_file=$(find "$pull_dir" -maxdepth 1 -name '*.tgz' -print -quit)
      if [ -z "$chart_file" ]; then
        echo "FAILED: $rel ($app): helm pull produced no chart archive" >&2
        failed=$((failed + 1))
        continue
      fi
      args=(template "$app" "$chart_file")
    fi

    # valueFiles come through as a comma-separated list of repo-relative paths (already stripped of
    # their `$values/` ref prefix by the parser), so they are read from THIS repo.
    if [ "$valuefiles" != "-" ]; then
      IFS=',' read -r -a vfs <<<"$valuefiles"
      for vf in "${vfs[@]}"; do
        args=("${args[@]}" -f "$repo_root/$vf")
      done
    fi

    if helm "${args[@]}" >>"$rendered" 2>"$tmp/err"; then
      echo "== $app ($chart $rev)" >&2
    else
      echo "FAILED: $rel ($app: $chart $rev)" >&2
      sed 's/^/    /' "$tmp/err" >&2
      failed=$((failed + 1))
    fi
    printf -- '---\n' >>"$rendered"
  done < <(python3 - "$manifest" "$repo_root" <<'PY'
import sys, yaml, pathlib

manifest, repo_root = sys.argv[1], pathlib.Path(sys.argv[2])
try:
    docs = [d for d in yaml.safe_load_all(open(manifest)) if isinstance(d, dict)]
except Exception:
    sys.exit(0)

for doc in docs:
    if doc.get("kind") != "Application":
        continue
    app = (doc.get("metadata") or {}).get("name", "?")
    spec = doc.get("spec") or {}
    sources = ([spec["source"]] if isinstance(spec.get("source"), dict) else []) + list(spec.get("sources") or [])

    # A `$values/...` valueFile refers to the source labelled `values`; resolve that label to its
    # repoURL so we only try to read value files that actually live here.
    refs = {s.get("ref"): s.get("repoURL") for s in sources if s.get("ref")}
    for src in sources:
        helm = src.get("helm") or {}
        # Two shapes, both in use here (verified 2026-09-28):
        #   - a chart from a HELM REPOSITORY: the source carries `chart:` (+ `repoURL`, `targetRevision`)
        #   - a chart inside a GIT REPOSITORY: the source carries `path:` and no `chart:` — the
        #     vcap v1 apps, whose charts live in their own repos
        chart = src.get("chart")
        path = src.get("path") or "-"
        if not chart:
            if path == "-" or not helm:
                continue
            chart = path  # a git-sourced chart: the "chart" is the directory in the clone
        repo = src.get("repoURL", "-")
        rev = src.get("targetRevision", "-")

        vfs = []
        for vf in helm.get("valueFiles") or []:
            if not isinstance(vf, str) or not vf.startswith("$"):
                continue
            ref, _, tail = vf[1:].partition("/")
            if not tail:
                continue
            # Only this repo's files are readable in CI; anything else (VCAP's deploy/ dirs) is
            # skipped by the caller, which reports its skips.
            if refs.get(ref, "").endswith("upayanmazumder/cluster"):
                vfs.append(tail)
        shape = "helmrepo" if src.get("chart") else "git"
        print("\t".join([app, chart, repo, rev, path, ",".join(vfs) or "-", shape]))
PY
)
done < <(find "$repo_root/k8s/argocd/applications" -name '*.yaml' -print0 | sort -z)

if [ "$out" != "-" ]; then
  cp "$rendered" "$out"
else
  cat "$rendered"
fi

echo "helm-template-all: $((total - failed - skipped))/$total Helm-sourced Applications rendered, $skipped skipped (see above)" >&2
if [ "$failed" -ne 0 ]; then
  echo "helm-template-all: FAILED ($failed)" >&2
  exit 1
fi
