---
name: cluster-validation
description: Run local validation scripts, lint checks, and pre-commit tests before pushing changes
---

# Cluster validation

Run local validation scripts before you push changes to GitHub.
CI requires all validation checks to pass.

## Quick validation commands

Run these commands from the repository root:

```bash
# 1. Validate application paths in ArgoCD manifests
python3 scripts/check-app-paths.py

# 2. Check documentation links
python3 scripts/check-links.py

# 3. Verify SOPS encryption on all secrets
bash scripts/check-secrets.sh

# 4. Check shell scripts with shellcheck
bash scripts/check-shellcheck.sh

# 5. Render all Kustomize directories to verify syntax
bash scripts/render-all.sh /tmp/all-manifests.yaml

# 6. Render Helm applications with active values
bash scripts/helm-template-all.sh /tmp/helm-manifests.yaml
```

## Infrastructure validation

### Terraform

Run Terraform validation with the wrapper script:

```bash
scripts/tf.sh init
scripts/tf.sh validate
```

### Ansible

Check Ansible playbook syntax:

```bash
ansible-playbook -i ansible/inventory.yaml ansible/site.yml --syntax-check
```

## Pre-commit checks

Run pre-commit hooks on all files:

```bash
pre-commit run --all-files
```

## Continuous integration jobs

GitHub Actions runs seven jobs on every pull request:

1. `kustomize-and-schema`: Renders manifests and checks schemas with kubeconform.
2. `lint`: Runs yamllint, gitleaks, and link checks.
3. `terraform`: Validates Terraform configurations.
4. `ansible`: Runs syntax checks on Ansible playbooks.
5. `redaction`: Scans for sensitive terms.
