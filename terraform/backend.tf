# **State lives in R2 (`s3://vps-tfstate/vps/terraform.tfstate`); the historical phase notes below are
# kept as the record of how it got there.** An earlier version of this header described "Phase 1: local
# backend" as the *current* state, which stopped being true when `terraform init -migrate-state` ran
# (TF-001, 2026-09-29) — the live `backend "s3"` block is further down this file, and a reader who
# believed the header would have tried to migrate state that had already moved. The phase notes are
# retained because they explain the chicken-and-egg (the configuration creates the bucket it stores
# its state in) and the "never commit state" rule.
#
# Before any of that (Phase 0, historical): a local backend, to be replaced once the bucket existed.
# terraform {
#   backend "s3" {
#     bucket                      = "vps-tfstate"
#     key                         = "vps/terraform.tfstate"
#     region                      = "auto"
#     endpoint                    = "https://<account-id>.r2.cloudflarestorage.com"
#     access_key                  = null # via AWS_ACCESS_KEY_ID env var (R2 API token)
#     secret_key                  = null # via AWS_SECRET_ACCESS_KEY env var
#     skip_credentials_validation = true
#     skip_region_validation      = true
#     skip_requesting_account_id  = true
#     use_lockfile                = true
#   }
# }
#
# Phase 2, exactly (decided 2026-09-29, TF-001):
#
#   1. Credentials — the owner provides a **bucket-scoped** R2 S3 token (Object Read & Write) for
#      `vps-tfstate` ONLY. Do not use the backup bucket's token here and do not use an account-wide
#      admin token: the two are separate by design, and neither is ever committed.
#        export AWS_ACCESS_KEY_ID=...        # from the owner, out of band
#        export AWS_SECRET_ACCESS_KEY=...
#   2. Uncomment the block above and replace `<account-id>`. **This parenthetical used to read "so it
#      is not written down here" — which is false:** the live `backend "s3"` block further down this
#      file carries the full endpoint, account id included, and has since the Phase 2 switch. The id
#      is not a credential (nothing can be done with it alone, and `cloudflare.tf` declares it as a
#      variable default too), but a comment that says a value is absent while the same file publishes
#      it is the kind of thing a reader trusts and should not. If it is ever to be kept out of the
#      tree, the backend takes it via `-backend-config=endpoints=...` — a backend block cannot
#      interpolate a variable — and that is a change to `scripts/tf.sh`, not to this comment.
#   3. terraform init -migrate-state        # local -> R2, carrying the existing state with it
#   4. terraform plan                       # must show NO changes; that is this task's validation
#   5. Back up the local state file offline before deleting it, then delete `terraform.tfstate*`
#      (gitignored, and it holds resource IDs and possibly sensitive attributes).
# **R2 does not implement S3 bucket versioning.** Verified 2026-09-29 against Cloudflare's own S3 API
# compatibility page (developers.cloudflare.com/r2/api/s3/api/), which lists both `GetBucketVersioning` and
# `PutBucketVersioning` under *Unimplemented bucket-level operations*, and against the account API, whose
# bucket resource returns only `creation_date`, `jurisdiction`, `location`, `name` and `storage_class` —
# there is no versioning field to set. An earlier note here asked for versioning to be enabled in the
# dashboard, saying it "cannot be Terraformed at this provider version"; the premise was wrong twice over.
# The protection that *does* exist on R2 is already configured: `use_lockfile = true` in the backend block,
# which stops two applies writing the state at once. **Bucket Lock is deliberately not used** — it is WORM,
# and Terraform has to overwrite the state object on every operation. The archive safeguard is the offline
# copy of the pre-R2 state under ~/.local/share/vps-tfstate-backup/ on the owner's workstation.

terraform {
  # Phase 2, switched 2026-09-29 (TF-001): state lives in the `vps-tfstate` R2 bucket, which this
  # configuration itself creates (it is in state, so the chicken/egg the earlier comments describe is
  # resolved). Credentials are the bucket-scoped S3 token, read from AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY in the environment -- never in this file, never in a committed .tfvars.
  backend "s3" {
    bucket = "vps-tfstate"
    key    = "vps/terraform.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://92454a06150c83347f179e1b10f6ab35.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}
