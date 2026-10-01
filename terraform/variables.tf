variable "hetzner_server_id" {
  description = "Existing Hetzner server ID to import (never create a second one)."
  type        = number
  default     = 122385524 # verified: docs/inventory.md, review §2.1
}

# Removed 2026-09-28 (CLEAN-002): `hetzner_primary_ipv{4,6}_id` and `vcap_{dev,staging}_volume_id`.
# They were declared and never referenced — the real ids live inline in `imports.tf`, where Terraform
# needs them for the import blocks, so these were duplicates that invited someone to set the wrong one
# and wonder why nothing changed. `terraform validate` passes without them.

variable "access_allowed_emails" {
  description = "Cloudflare Access allow-list for the ArgoCD/Grafana admin UIs (N3; not yet applied). Empty by default — the value belongs in a git-ignored *.auto.tfvars (TF-003)."
  type        = list(string)
  # Deliberately EMPTY, and deliberately still declared (SEC-006 + TF-003 + CI-007, 2026-09-28):
  #   - the owner's address used to be the default here, which made this file one of the six
  #     publication blockers `docs/plans/redaction-checklist.md` tracks — a personal email in a file
  #     the public repo would carry. The value belongs in a git-ignored `*.auto.tfvars` (TF-003);
  #   - the *declaration* stays because N3 (Cloudflare Access in front of ArgoCD and Grafana) needs
  #     it, and removing the seam would just move the work to that task without removing the PII.
  #     Until 2026-09-29 it was also reported by tflint as unused, which is why
  #     `terraform_unused_declarations` is disabled in `.tflint.hcl`; `access.tf` now consumes it, so
  #     that disable is no longer load-bearing for this variable (left in place, since tflint cannot be
  #     run from the workstation — see the 2026-09-29 changelog entries on linters that only exist in CI).
  default = []
}

variable "enable_cloudflare_access" {
  description = "Create the Cloudflare Access applications and allow-policies in front of the ArgoCD/Grafana UIs (N3). Off by default: with it off, `terraform plan` shows no changes."
  type        = bool
  default     = false

  # The guard that refuses an empty allow-list lives in `access.tf` as a `lifecycle.precondition`, NOT
  # here as a `validation`. That is not style: **a variable validation may only refer to its own
  # variable**, and this check is about two variables agreeing. Terraform 1.15 accepts the cross
  # reference; the version CI pins (~> 1.7) rejects it at `terraform init` with "Invalid reference in
  # variable validation" — which is precisely the bug that broke this repository's `terraform` job on
  # P3-04 (fixed in `2500dc9`), reproduced here because the same shape was written again. See the
  # changelog entry for 2026-09-29 naming that repeat.
}

variable "cloudflare_access_api_token" {
  description = "N3: the Cloudflare API token used by the Access resources only (provider alias `cloudflare.access`). Supplied as `TF_VAR_cloudflare_access_api_token` from the SOPS secrets file; never in a committed file."
  type        = string
  sensitive   = true
  default     = ""

  # Empty by default, and with `enable_cloudflare_access` now defaulting to **true** that empty
  # value is what makes a credential-less checkout stop rather than guess: the second
  # `precondition` in `access.tf` refuses the plan and names this variable. It is refused there and
  # not here because a variable validation cannot see another variable (see the note above).
}

variable "emergency_ssh_cidr" {
  description = "Temporary /32 CIDR to allow tcp/22 through the Hetzner firewall for break-glass recovery when Tailscale is unreachable (S6 target state). Empty = no rule. Remove after use — this is a manual, confirmed, temporary override, never left set."
  type        = string
  default     = ""
}

variable "cloudflare_zone_name" {
  description = "The zone this repo's Terraform manages. codechefvit.com is explicitly out of scope."
  type        = string
  default     = "upayan.dev"
}

variable "cloudflare_only_ingress" {
  description = "N4: restrict the 80/443 firewall rules to Cloudflare's published ranges. Now ON (N4 landed 2026-09-29); set back to false to revert in one apply."
  type        = bool
  default     = true

  # Flipped to true when N4 landed (2026-09-29), the same day Cloudflare Access did.
  #
  # Why N4 was urgent rather than merely ordered after N3: measured, with Access live, a request to the
  # **origin** over 443 carrying the right Host header reached ArgoCD directly — `HTTP/2 200` from
  # `curl -sk --resolve argocd.upayan.dev:443:138.201.157.147` — i.e. the Access policy was bypassable
  # by anyone who resolves the origin IP, which the public DNS record makes trivial. Access is enforced
  # at Cloudflare's edge, so it only means anything once the edge is the *only* way in. That is exactly
  # what this flag does, and the 25 proxied hostnames are unaffected because Cloudflare still reaches
  # the origin from its own ranges.
  #
  # Kept as a variable rather than folded into the rules so the revert is one variable and one apply.
}
