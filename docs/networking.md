# Networking

Port-by-port detail lives in [`ports.md`](ports.md) and
[`../inventory/ports.yaml`](../inventory/ports.yaml).
This page covers the layers.

## Current state

A Hetzner Cloud Firewall named `vps` is attached.
Terraform manages it as an allow-list.
The repository declares these rules:

| Rule | Source | Note |
|---|---|---|
| tcp/22 | Tailscale only | Public IPv4 and IPv6 rules removed |
| tcp/80, tcp/443 | Cloudflare published ranges | Built from `data.cloudflare_ip_ranges` |
| tcp/6443 | Tailscale only | Public IPv4 and IPv6 rules removed |
| udp/41641 | `0.0.0.0/0`, `::/0` | Tailscale NAT traversal |
| icmp | `0.0.0.0/0`, `::/0` | Answered |

TCP `15432`, TCP `15433`, TCP `15434`, TCP `7881`, and UDP `7882` are absent from the repository.
Their last consumers were the vcap v2, vcap v1, and kirro workloads.
Terraform applied the v2 and kirro removals to firewall `11692068` on 2026-10-23.
Terraform applied the `15434` removal on 2026-10-27.
Public probes confirm that ports `15432`, `15433`, and `15434` are closed.
`7881` is closed too.

All other ports are dropped. Host `iptables` INPUT policy is `ACCEPT`. `ufw` is inactive.
No `fail2ban` runs. The cloud firewall is the only packet filter.

Closed by the absence of rules:

- kubelet `10250`
- etcd client and peer `2379` and `2380`
- flannel VXLAN `8472`
- node-exporter `9100`
- Traefik NodePorts

Some of these ports are still bound on the host. The firewall makes them unreachable.

On 2026-11-22, Terraform removed the public SSH and Kubernetes API rules from firewall `11692068`.
The workstation uses `100.96.250.81` for both `ssh vps` and its Kubernetes API endpoint.
OpenSSH still requires the existing SSH key. Tailscale SSH remains disabled.
No exit node, subnet route, host firewall, or Kubernetes forwarding rule changed.
The provider refreshed the Cloudflare source list from 68 to 69 ranges without removing existing ranges.

The tailnet contains PC `sonder`, phone `Solace`, VPS `vps`, and four offline devices.
The approved policy is stored in [`../ansible/files/tailscale-policy.hujson`](../ansible/files/tailscale-policy.hujson).
Apply this file through the Tailscale console JSON editor. Ansible does not upload it.
The console validates 15 tests before saving.

| Source | VPS access |
|---|---|
| PC `sonder` | TCP 22 and 6443 |
| Phone `Solace` | TCP 22 |
| Other devices | Denied |

The VPS cannot initiate connections to other tailnet devices.
Response traffic for permitted administrative connections remains allowed.
Other tailnet devices retain their existing connectivity, including subnet `10.42.1.0/24`.
New subnet routes require a separate policy review.
Device rules include both IPv4 and IPv6 addresses.
Replacing an administrative device requires updating the policy.
Normal internet traffic does not traverse these grants.
The separate Tailscale SSH policy remains unchanged. The VPS uses OpenSSH with its existing keys.

Manual approval for new devices is enabled and survived a console reload.
Existing devices remain enrolled. Tailnet Lock remains disabled.
Google account MFA remains unverified.
Live checks confirmed PC private SSH, API readiness, and IPv6 administrative TCP access.
PC access to VPS kubelet timed out. VPS access to PC SSH timed out.
Phone SSH permission passed policy validation, but phone key authentication was not tested.
The original policy backup remains private under the workstation's `.local/state/` directory.
Restore that policy through the console if a tailnet policy recovery is necessary.
The VPS node key expires on 2027-01-08.
Renew it before expiry to preserve private administration.

Recovery does not require public SSH to remain open.
Use the Hetzner console or rescue system if Tailscale fails.
Alternatively, review a targeted Terraform plan with `-var='emergency_ssh_cidr=YOUR_PUBLIC_IP/32'`.
Apply that plan with `scripts/tf.sh`, then remove the override immediately after recovery.
Retain SSH key authentication throughout recovery.

Verification confirmed private SSH, API readiness, a Ready node, and VPS outbound HTTPS.
Public IPv4 probes timed out on TCP 22, 6443, 2379, 2380, and 10250.
The workstation lacked IPv6 connectivity. Provider rules confirm no IPv6 SSH or API allow rule.
Public application checks retained their existing HTTP 410 responses or certificate errors.
These errors preceded the firewall change. They do not prove healthy public applications.

## vcap Postgres exposure (retired)

> **Retired 2026-10-27.** vcap v1 is retired. No database port is open.

Traefik no longer has entrypoint `vcap-pg-v1`. `IngressRouteTCP/vcap-v1-postgres` and TLSOption
`vcap-pg` are removed. `pg-v1.upayan.dev:15434` is closed. The firewall allows no database port.

The v2 entrypoints and routes are gone too.
The retained `vcap-dev`, `vcap-staging`, and `vcap-v1` data serves no traffic.
Do not add a listener or firewall rule for retained data.
To recover the retained v1 data, see [`runbooks/restore-postgres.md`](runbooks/restore-postgres.md).

## NetworkPolicy posture

Every app namespace denies ingress by default. The patterns:

| Shape | Namespaces | Allowed ingress |
|---|---|---|
| KEDA HTTP fronted | `cas-api`, `dj-html-nodejs-web`, `learning-docker`, `learning-qwik`, `smart-home-system-api` | Interceptor pod in namespace `keda` only |
| Direct Traefik | `cheatsheet`, `kodesphere`, `learning-react`, `meghmitra`, `prism-streaming-rag`, `status-page`, `upayan-api` | Traefik in `kube-system`; `upayan-api` admits Traefik only |
| No ingress | `mochi` | Nothing. Outbound Discord bot |

Datastore pods allow same-namespace traffic only.

Two rules:

- Intra-namespace rules use an empty `podSelector`. The namespace is the trust boundary.
- Policies for charts that ship none live in this repository, next to the app manifests.

The retained namespaces, including `vcap-v1`, run no pods. Their NetworkPolicies do nothing.

## Target architecture

Three layers, one owner each:

```text
Cloudflare (proxy, Full strict, Always HTTPS)
   │ 80/443 only, from Cloudflare ranges
Hetzner Cloud Firewall "vps" (Terraform-managed)
   │ allow: 80,443 (Cloudflare) · 41641/udp (Tailscale) · icmp
   │ drop: everything else, including tcp 22 and 6443
Host (Ansible-managed)
   │ Tailscale is the only path to SSH (22), k3s API (6443), kubelet (10250)
```

Decisions:

- **No database port is public.** vcap v1 was retired on 2026-10-27 and TCP `15434` is closed.
- **Admin plane is Tailscale-only.** No public SSH and no public API. Last-resort access is the
  Hetzner console or rescue system. See [`runbooks/recover-vm.md`](runbooks/recover-vm.md).
- **The Hetzner firewall is the only packet filter managed by this repository.** Do not add
  `ufw` or `nftables` rules from Ansible. They conflict with kube-proxy and kube-router.
- **No listener without a consumer.** Do not add a Traefik entrypoint, firewall rule, or
  `IngressRouteTCP` for retained data.

## Related

- [`ports.md`](ports.md) and [`../inventory/ports.yaml`](../inventory/ports.yaml)
- [`certificates.md`](certificates.md)
- [`secrets.md`](secrets.md)
- [`runbooks/add-port.md`](runbooks/add-port.md)
