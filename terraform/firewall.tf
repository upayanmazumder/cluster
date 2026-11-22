# VPS firewall (live).
#
# Inbound: tcp/80 and tcp/443 from Cloudflare, udp/41641, and icmp.
# SSH and the Kubernetes API use Tailscale only. No database port is open.
#
# TCP 15432/15433 (v2 Postgres), TCP 15434 (v1 Postgres), and LiveKit TCP 7881/UDP 7882 were
# removed with the retired workloads (2026-10-23 and 2026-10-27). This file is the source of truth.
# `inventory/ports.yaml` records the same ports, and `scripts/check-ports.py`
# compares the two.
#

# N4 (P7): restrict 80/443 to Cloudflare's edge. Fetched, never hand-copied — a static list rots
# silently, and a wrong range list here is a total ingress outage (Cloudflare can reach nothing, every
# host 5xx). The provider data source was confirmed present in the pinned version
# (`terraform providers schema`: `cloudflare_ip_ranges` exposes `ipv4_cidr_blocks`, `ipv6_cidr_blocks`,
# `china_ipv4_cidr_blocks`, `china_ipv6_cidr_blocks`).
#
# **Hetzner caps a rule's `source_ips` at 100 CIDRs, and all four lists do not fit.** Measured
# 2026-09-29 by bisecting an unattached throwaway firewall (nothing touched the live one):
# `ipv4(15) + ipv6(7) + china_ipv4(46) + china_ipv6(44) = 112` → the API answers
# `invalid input … source_ips => [value required to be smaller]`; 100 entries are accepted and 101 are
# not. (The first attempt to apply this rule failed exactly that way, which is how the cap was found;
# the failed apply changed nothing, confirmed by re-reading the firewall.)
#
# So **`china_ipv6_cidr_blocks` is excluded**, which loses nothing real: Cloudflare's own published
# `https://www.cloudflare.com/ips-v6-china` now returns an **empty** list, so the provider's 44
# china-IPv6 entries are stale ranges Cloudflare no longer advertises. `china_ipv4_cidr_blocks` **is**
# still published (46 live entries) and stays, because Cloudflare's China network reaches origins from
# those and a silently dropped visitor is indistinguishable from a broken site. The result is 68
# entries per rule — under the cap with headroom, and every currently-advertised Cloudflare range
# present. If Cloudflare ever republishes china-IPv6, this needs a different shape (a second rule or
# N6's nftables set, which has no such cap), not a longer list.
data "cloudflare_ip_ranges" "cf" {}

locals {
  # Gated, so that the applied firewall is provably the intended one: with the flag off this is
  # byte-identical to the `["0.0.0.0/0", "::/0"]` it replaces, and `terraform plan` reports no changes.
  #
  # Administrative ports have no public rule. Tailscale carries that traffic over UDP 41641.
  http_https_source_ips = var.cloudflare_only_ingress ? concat(
    data.cloudflare_ip_ranges.cf.ipv4_cidr_blocks,
    data.cloudflare_ip_ranges.cf.ipv6_cidr_blocks,
    data.cloudflare_ip_ranges.cf.china_ipv4_cidr_blocks,
    # china_ipv6_cidr_blocks deliberately omitted: stale, and it would push the rule past Hetzner's
    # 100-CIDR cap. See the header comment.
  ) : ["0.0.0.0/0", "::/0"]
}

resource "hcloud_firewall" "vps" {
  name = "vps"

  # Inbound
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = local.http_https_source_ips
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = local.http_https_source_ips
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Break-glass only: set via `-var emergency_ssh_cidr=<ip>/32` and apply, then re-apply with it
  # unset immediately after use. Empty by default = no extra rule.
  dynamic "rule" {
    for_each = var.emergency_ssh_cidr != "" ? [1] : []
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = [var.emergency_ssh_cidr]
    }
  }
}

resource "hcloud_firewall_attachment" "vps" {
  firewall_id = hcloud_firewall.vps.id
  # TF-004 (P3-04): the rebuild node joins this set rather than carrying its own `firewall_ids`.
  # One owner for firewall membership, so a plan that creates the rebuild server cannot also be a
  # plan that detaches the existing one. `[*]` on a `count = 0` resource is the empty list, so with
  # the rebuild variable off this is byte-identical to the previous behaviour.
  server_ids = concat([hcloud_server.vps.id], hcloud_server.rebuild[*].id)
}

