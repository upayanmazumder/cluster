# Terraform — provider layer

Owns: the Hetzner server (imported), primary IPs, the Hetzner firewall, R2 buckets, the Cloudflare
zone settings, and (once `cf-terraforming`'s import plan is zero-diff) the zone's DNS records. Never
owns anything inside the VM or Kubernetes — see `../docs/maintenance.md#ownership-model`.

Status: **applied, 2026-10-23.** `terraform state list` tracks 15 managed resources: the Hetzner
server, primary IPs, SSH keys, data volume, firewall and attachment, both R2 buckets, the Cloudflare
Access applications and policies, and the zone settings override. The 2026-10-23 apply removed
inbound TCP `15432`, TCP `15433`, TCP `7881`, and UDP `7882` from `hcloud_firewall.vps`. The plan was
`0 to add, 1 to change, 0 to destroy`. A rule-by-rule diff confirmed that only those four rules left
the ruleset. See the changelog for the full apply history.

State lives in the `vps-tfstate` R2 bucket (`s3://vps-tfstate/vps/terraform.tfstate`) since
2026-09-29 (TF-001). `backend.tf` holds the live S3 backend. R2 has no bucket versioning, so the only
archive is the offline copy under `~/.local/share/vps-tfstate-backup/` that `scripts/tf.sh` writes
before every state-writing command.

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Provider version pins |
| `providers.tf` | Provider auth (env vars only, never hardcoded tokens) |
| `backend.tf` | Live R2 S3 backend for `s3://vps-tfstate/vps/terraform.tfstate` |
| `variables.tf` | Known IDs (server, volumes-not-managed) + Access allow-list + emergency-SSH escape hatch |
| `hcloud.tf` | Server (imported, verified via API) + primary IPs (protection/auto_delete applied) |
| `ssh-keys.tf` | Both SSH keys, imported with real public-key bodies fetched from the Hetzner API |
| `firewall.tf` | Firewall allow-list, attached and live. Removed the v2 and kirro ports on 2026-10-23 |
| `cloudflare.tf` | Zone settings, imported and applied. R2 buckets. **No DNS records** |
| `imports.tf` | Declarative `import` blocks — all 5 importable resources active with real, verified IDs |
| `outputs.tf` | Server IDs/IPs, firewall ID, bucket names |

## What remains

1. **DNS records** — deliberately not written. Run `cf-terraforming` against the live zone first.
   See the comment at the top of `cloudflare.tf`.
2. **Checkout setup** — `enable_cloudflare_access` defaults to **true**. A checkout without the
   git-ignored `access.auto.tfvars` fails the plan on a precondition instead of planning to destroy
   the Access applications. Supplying `access_allowed_emails` is part of a working checkout. See the
   header of `access.tf`.

## Bootstrap sequence (for a fresh checkout, credentials already known)

Use the sanctioned wrapper from the repository root. It reads the encrypted provider credentials
at `~/.config/vps/terraform/secrets.enc.env`, checks the repository origin, and snapshots remote
state before every state-writing command.

```bash
scripts/tf.sh init
scripts/tf.sh plan -out=/dev/shm/tfplan
scripts/tf.sh apply /dev/shm/tfplan
```

A fresh checkout initializes directly against the R2 backend in `backend.tf`. There is no local
state to migrate. `terraform.tfstate` stays gitignored. Never delete a state copy by hand. Use the
snapshots under `~/.local/share/vps-tfstate-backup/` and the changelog recovery steps instead.

## Related

- `../docs/networking.md` — the firewall layers this config implements
- `../docs/certificates.md` — the `min_tls_version` finding and TLS design
- This directory was written from the private architecture review's S2/S6 stage brief. That document is
  **not** published (it lives under `docs/plans/`, which the export excludes), so it is described here
  rather than linked — a link to it would dangle for every reader of the public tree.
- `../changelog/2026-09.md` — full apply history and the recovered state-loss mistake

## The Terraform version, and why it is pinned twice

CI pins Terraform **exactly** (`.github/workflows/validate.yml` → `terraform_version: "1.7.5"`), and
`terraform/.terraform-version` carries the same value so a version manager picks it up on a workstation.

**Run `terraform validate` with that version, not whatever `terraform` happens to be on your `PATH`.** The
difference is not theoretical — it has already cost this repository two red CI runs:

| Commit | Bug | Why the local run said "fine" |
|---|---|---|
| `2500dc9` (P3-04) | `variable "enable_rebuild_server"` had a `validation` referencing `var.rebuild_server_tailscale_auth_key` | a `variable` validation may only reference **its own** variable. The workstation's Terraform 1.15 accepts the cross-reference; the pinned 1.7 rejects it at `terraform init` |
| `1f73356` (N3) | the identical shape, in `variable "enable_cloudflare_access"` | same |

Both were fixed the same way: move the "these two variables must agree" check to a
`lifecycle.precondition` on the resource the variables configure, which may reference both and is
evaluated only when that resource is planned.

**The rule this leaves behind:** a local `terraform validate` is evidence for *the version that ran it* and
for nothing else. If you write a cross-variable check, run it against 1.7.5 before pushing:

```bash
mkdir -p /tmp/tf-pinned && cp terraform/*.tf terraform/.terraform.lock.hcl /tmp/tf-pinned/
cd /tmp/tf-pinned && /path/to/terraform-1.7.5 init -backend=false && terraform validate
```
