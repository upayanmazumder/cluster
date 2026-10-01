# Terraform — provider layer

Owns: the Hetzner server (imported), primary IPs, the Hetzner firewall, R2 buckets, and (once
`cf-terraforming`'s import plan is zero-diff) the Cloudflare zone's DNS records and settings. Never
owns anything inside the VM or Kubernetes — see `../docs/maintenance.md#ownership-model`.

Status: **applied, 2026-09-28.** `terraform state list` tracks 9 real resources: `hcloud_server.vps`
(imported), `hcloud_primary_ip.{ipv4,ipv6}` (imported), `hcloud_ssh_key.{vps_root,upayan_sonder}`
(imported), `hcloud_firewall.vps` + `hcloud_firewall_attachment.vps` (created, permissive — mirrors
the pre-existing open state, changed no traffic), `cloudflare_r2_bucket.{vps_backups,vps_tfstate}`
(created), `cloudflare_zone_settings_override.upayan_dev` (created, imports the zone's real current
settings). See `../changelog/2026-09.md` (2026-09-28 entries) for the full apply history, the
schema/doc errors it caught, and a state-loss mistake that was made and fully recovered in the same
sitting.

State lives in the `vps-tfstate` R2 bucket (`s3://vps-tfstate/vps/terraform.tfstate`) since
2026-09-29 (TF-001). This paragraph used to say "local only — the planned R2 backend migration
hasn't happened yet", which `backend.tf`'s own header already corrected; both now agree. R2 has no
bucket versioning, so the only archive is the offline copy under
`~/.local/share/vps-tfstate-backup/` that `scripts/tf.sh` writes before every state-writing command.

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Provider version pins |
| `providers.tf` | Provider auth (env vars only, never hardcoded tokens) |
| `backend.tf` | Local backend for now; commented-out R2 backend block, ready once an R2 API token exists |
| `variables.tf` | Known IDs (server, volumes-not-managed) + Access allow-list + emergency-SSH escape hatch |
| `hcloud.tf` | Server (imported, verified via API) + primary IPs (protection/auto_delete applied) |
| `ssh-keys.tf` | Both SSH keys, imported with real public-key bodies fetched from the Hetzner API |
| `firewall.tf` | Permissive firewall (S2), attached and live |
| `cloudflare.tf` | Zone settings (imported real values; `min_tls_version` was found to be `1.0`, not the 1.2 the docs assumed — now declared as 1.2 per NET-005, **not yet applied** because the apply needs a Zone Settings token), R2 buckets (created) — **no DNS records** |
| `imports.tf` | Declarative `import` blocks — all 5 importable resources active with real, verified IDs |
| `outputs.tf` | Server IDs/IPs, firewall ID, bucket names |

## What's still blocked

1. **R2 backend migration** — needs an **R2 API token** (S3-compatible access key/secret pair,
   generated separately in the Cloudflare dashboard: R2 → "Manage R2 API Tokens"). This is a
   *different* credential from the Cloudflare API token already supplied (that token doesn't grant
   S3-compatible access on its own). Until this exists, `terraform.tfstate` stays local — **do not
   delete it** (a past mistake, recovered — see the changelog); if it must be regenerated, run
   `terraform import` for every resource in `imports.tf` plus `hcloud_firewall.vps`,
   `hcloud_firewall_attachment.vps`, `cloudflare_r2_bucket.{vps_backups,vps_tfstate}` (format:
   `<account-id>/<bucket-name>`) — `cloudflare_zone_settings_override` does **not** support import
   at all in this provider version; re-applying it is a safe idempotent re-PUT of already-live
   values, not a duplicate.
2. **DNS records** — deliberately not written; run `cf-terraforming` against the live zone first
   (see the comment at the top of `cloudflare.tf`).
3. ~~**Cloudflare Access apps** (ArgoCD/Grafana)~~ — **done.** N3 landed 2026-09-29; `access.tf`
   holds them and `enable_cloudflare_access` now defaults to **true**, so a checkout without the
   git-ignored `access.auto.tfvars` fails the plan on a precondition instead of planning to destroy
   the applications. Supplying `access_allowed_emails` is therefore part of setting up a working
   checkout, not an optional extra — see the header of `access.tf`.

## Bootstrap sequence (for a fresh checkout, credentials already known)

```bash
cd terraform
export HCLOUD_TOKEN=...
export CLOUDFLARE_API_TOKEN=...

terraform init
terraform plan   # should show 0 to import missing (already in state)/0 to change/0 to destroy
                 # if state is missing, plan will show imports for everything in imports.tf —
                 # that's expected and safe, they're declarative
terraform apply  # only after reviewing the plan; paste the summary for confirmation first
```

Once the R2 backend token exists: uncomment the `backend "s3"` block in `backend.tf`,
`terraform init -migrate-state`, confirm state lands in the `vps-tfstate` bucket, then stop treating
the local `terraform.tfstate` as authoritative (it stays gitignored either way).

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
