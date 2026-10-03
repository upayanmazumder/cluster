# S2: created PERMISSIVE — mirrors today's de-facto-open state so attaching it changes nothing
# yet. The final locked-down ruleset is a separate, later change to this file — do not jump ahead
# to it here.
#
# Postgres ports — N7 (2026-09-29). **The 5432/5433 rules are gone** (they were a leftover: nothing
# served them, and leaving a world-open rule for a port that "must not reopen" is exactly the
# inherited accident OD-1 exists to remove) and the target path **15432 (dev) / 15433 (staging)** is
# opened deliberately, one port at a time.
#
# The hardening this depends on now exists: TLS at Traefik with a private-CA leaf (verified by
# handshake), a non-superuser application role that the app actually uses (verified in
# `pg_stat_activity`), a `pg_hba.conf` that refuses the bootstrap superuser over TCP (verified from a
# non-loopback client: `FATAL: pg_hba.conf rejects connection … user "vcap_user"`), per-person
# read-only roles, an additive NetworkPolicy admitting only Traefik, and auth-failure alerting.
#
# **15432 opens first, and 15433 only after 15432 has been exercised by a real client** — the plan is
# explicit, and staging holds the real data. Add the second port as its own reviewed change.

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
  # Only 80 and 443 are affected. 22 and 6443 are NOT narrowed here: that is N5, and it depends on a
  # working tailnet (N2) rather than on Cloudflare.
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
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
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
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  # N7: the VCAP Postgres edge, dev first. Public by design (OD-1), TLS-required by the edge
  # router. 15433 is deliberately NOT here yet: staging opens only after 15432 has been exercised.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "15432"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  # 15433 opened 2026-09-29 after 15432 had been exercised by a real client through the edge
  # (TLS verified against the CA, the per-person role reading and refused a write, the superuser
  # refused) -- the plan's ordering, and staging holds the real data.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "15433"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  # V1-CUTOVER (2026-10-03): v1's public Postgres edge (`vcap-pg-v1`,
  # k8s/platform/traefik/traefik-config.yaml), owner-requested so v1's database
  # is reachable directly without Cloudflare Access. TLS-required by the router
  # (its own CA — see k8s/apps/vcap-v1/edge/secrets.sops.yaml), same shape as
  # the two rules above. Registered in inventory/ports.yaml, which
  # scripts/check-ports.py cross-checks against this file.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "15434"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  # The `kirro` voice channel's WebRTC media (2026-10-02). LiveKit's self-hosted room server
  # (k8s/apps parity: the manifests live in Cheetos-gif/kirro, namespace `kirro`) carries browser
  # audio, and media **cannot** go through Traefik or any Kubernetes Ingress -- only the signalling
  # WebSocket can, and that one arrives on 443 like every other `*.upayan.dev` host. So these two
  # are reachable directly on the node's address, which is why they need rules at all.
  #
  # Two ports, not LiveKit's default 50000-60000 range: `rtc.udp_port` is set to a single muxed UDP
  # port in the app's ConfigMap, deliberately, so the internet-facing surface is one UDP port plus a
  # TCP fallback instead of ten thousand. The TCP port is the fallback for networks that block UDP
  # (corporate wifi, some mobile carriers); without it those callers get no audio at all.
  #
  # Both are public by design (`source_ips = 0.0.0.0/0`): any browser that can reach
  # voice-kirro.upayan.dev must also be able to reach the media path, and the caller's address is
  # not knowable in advance. Authorisation is the signalling JWT -- a room join token signed with the
  # key pair in the `kirro-voice` Secret, which the portal mints only for a signed-in user -- not
  # source-IP restriction. Ports are registered as `live` in inventory/ports.yaml; the registry and
  # this file are cross-checked by scripts/check-ports.py.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "7881"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "7882"
    source_ips = ["0.0.0.0/0", "::/0"]
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

# S6 target (not yet applied — tracked here as the documented next step, do not act on this
# comment without the S6 stage's own confirmation gate):
#   - keep the 5432/5433 from-anywhere rules — that part is permanent, owner-confirmed
#   - restrict 80/443 source_ips to Cloudflare's published ranges
#   - remove the plain tcp/22 and tcp/6443 rules entirely (Tailscale is the only admin path)
#
# Before you touch this, two things (both verified 2026-09-28):
#
#  1. PREREQUISITE: Tailscale must actually be working on every admin machine first. Removing the
#     public 22/6443 rules is only safe if the tailnet path exists, and today it does not for at
#     least one admin workstation (`tailscale` is not even installed there, and the kubeconfig
#     points at `https://138.201.157.147:6443`, i.e. the public address). Locking 6443 first would
#     cut `kubectl` for whoever is working from such a machine — ArgoCD itself is unaffected
#     in-cluster. Keep SSH reachable until the tailnet path is proven from every admin machine.
#     Also note the server is currently reachable on 6443 from the public internet (confirmed by
#     probing the port from a workstation), which is exactly what this change is for.
#
#  2. CLOUDFLARE RANGES: fetch them, do not hand-maintain a static list. The public, no-auth
#     endpoint works and is what the S6 executor should use:
#       curl -s https://api.cloudflare.com/client/v4/ips | jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]'
#     (15 IPv4 + 7 IPv6 ranges as of 2026-09-28). The comment that used to sit here suggested a
#     provider data source. **Confirmed 2026-09-28 against the pinned provider** (`cloudflare ~> 4.0`,
#     `terraform providers schema`): `data.cloudflare_ip_ranges` exists and is not deprecated, exposing
#     `ipv4_cidr_blocks` and `ipv6_cidr_blocks` — so the data source is the better route and the API
#     fetch above is the fallback, not the other way round.
#
#     **One decision that data source makes explicit and a hand-copied list hides:** it also exposes
#     `china_ipv4_cidr_blocks` / `china_ipv6_cidr_blocks`. Cloudflare's China network reaches the origin
#     from those ranges, so a rule built from the main lists alone silently drops that traffic. Either
#     include them deliberately or record that China-network visitors are out of scope — do not discover
#     it after the apply.
#
# Reminder of why this is deferred rather than done: the failure mode is a total ingress outage
# (Cloudflare can reach nothing, every host 5xx) plus loss of kubectl, and it is reversible only
# through the Hetzner Cloud console (which the owner holds) or from an already-open session.
