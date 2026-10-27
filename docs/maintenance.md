# Maintenance

Full detail: the architecture review (private, not published) §2.3 (host state) and §8 (ownership
model).

## Before you touch anything

Read [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md) and [`../AGENTS.md`](../AGENTS.md) first — this
page doesn't restate their hard rules. In short: cluster-affecting changes go through git, not
break-glass `kubectl`, except the small permitted set both docs list; every change (git or
break-glass) gets a `changelog/` entry; and — specific to this architecture programme — nothing
marked ⚠️ in the architecture review (private, not published) §17 runs without explicit confirmation
first.

## Ownership model {#ownership-model}

One owner per layer — Ansible for the host (this repo's `ansible/`), Terraform for the provider
layer (in the `cluster` checkout, `cluster/terraform/`), k3s for the runtime, ArgoCD for the
Kubernetes objects:

| Layer | Tool | Owns | Must never own |
|---|---|---|---|
| Provider | Terraform (`cluster/terraform/`) | hcloud server (imported, `prevent_destroy`), primary IPs, firewall, `vps-data` volume, server backup flag, SSH keys; Cloudflare DNS records (zero-diff import only), zone SSL/HTTPS settings, R2 buckets, Access apps/policies | anything inside the VM or Kubernetes |
| First boot (new VMs only) | cloud-init (rendered by Terraform) | admin user + SSH key + python3 + tailnet join | ongoing config |
| Host | Ansible (`ansible/`) | packages, sshd, unattended-upgrades, journald/atop limits, volume mount, Tailscale, k3s install/config, kubelet GC thresholds, restic + backup timer, healthchecks ping | Kubernetes objects |
| Runtime | k3s | control plane, CoreDNS, bundled Traefik chart, local-path provisioner, ServiceLB | — |
| Kubernetes | ArgoCD (`k8s/`) | every Kubernetes object except the bootstrap set below | host, provider |
| Bootstrap (manual, documented) | `kubectl` once | ArgoCD install, `argocd/sops-age` Secret, root Application | — |
| App repos | their owners | chart templates and digest pins for hello-kitty | secrets (values with secrets stay in this repo, encrypted) |

**Hard rule**: no two layers ever own the same resource. If you're about to add something, check
which layer already owns adjacent state before picking where it goes.

Firewall ownership: the Hetzner Cloud Firewall is the only packet filter this repo's tooling
manages — no `ufw`/`nftables` rules from Ansible.

## Routine tasks / disk hygiene

Current host state (verify against live before acting — this is a snapshot from the 2026-09-27
review):

| Item | State | Target |
|---|---|---|
| Root disk `/` | 75G, ~73% used | < 60% (S8 moves the biggest movable data off) |
| containerd images | ~30 GB (65 images) | kubelet image-gc-high/low thresholds 75%/60% (S3) |
| journald | 4.1 GB | `SystemMaxUse=500M` (S3) |
| atop | 1.1 GB | 7-day retention (S3) |
| etcd DB | 523 MB dir | unchanged; snapshots go offsite at S4 |
| Prometheus TSDB | 3.3 GB | `--storage.tsdb.retention.size=4GB` cap (S9) |
| Loki chunks | 5.2 GB, retention unenforced | 7-day compactor retention (S9) |

## Related

- [`upgrade-policy.md`](upgrade-policy.md) — target cadence for OS/k3s/ArgoCD/chart upgrades
- [`architecture.md`](architecture.md) — how the layers above fit together
- [`../changelog/`](../changelog/) — log every change here, no exceptions
