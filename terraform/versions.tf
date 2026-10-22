terraform {
  required_version = ">= 1.7"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0" # pinned major per the review §17 S2 — bump deliberately via PR, never float
    }
  }

  # State lives in the `vps-tfstate` R2 bucket. The live S3 backend is in backend.tf.
  # Use scripts/tf.sh from the repository root. It decrypts the provider credentials
  # and snapshots remote state before any state-writing command.
}
