# Monitoring

All monitoring manifests live in `k8s/monitoring/` and are reconciled by the `monitoring`
Application. This page describes the live stack on 2026-10-23.

## Stack

| Component | Kind | Data | Notes |
|---|---|---|---|
| Prometheus | Deployment, 1 replica | `prometheus-pvc`, 3.8 GB live | 7-day time retention, 4 GB size cap |
| Grafana | Deployment, 1 replica | `grafana-pvc`, sqlite | `strategy: Recreate`, admin password reset from SOPS on every start |
| Loki | Deployment, 1 replica | `loki-pvc`, 3.4 GB live | 168-hour retention through the compactor |
| Promtail | DaemonSet | none | Ships pod logs to Loki |
| kube-state-metrics | Deployment | none | Cluster object metrics |
| node-exporter | DaemonSet | host textfile collector | No `hostNetwork`, not public |

The Grafana admin init container `reset-admin-password` runs
`grafana cli ... admin reset-admin-password --password-from-stdin` on every start.
The SOPS Secret is therefore authoritative. A password change in the UI diverges from git.
It reverts on the next Grafana restart. Change the password in
`k8s/monitoring/secrets.sops.yaml`, never in the UI.

`grafana-create-dev-user` is an ArgoCD **PostSync hook**, not a plain Job.
It has `backoffLimit: 2` and `activeDeadlineSeconds: 600`.
The hook creates or updates three Viewer accounts:

- `vcap-dev@upayan.dev`
- `vcap-staging@upayan.dev`
- the KIRRO address from `grafana-kirro-credentials`

The hook deletes stale accounts with the same address. It runs on every sync of the
`monitoring` Application. The credentials remain in `k8s/monitoring/secrets.sops.yaml` because
the retained vcap and kirro data has no other read path for their owners.

## Dashboards

`grafana-dashboards` is a generated ConfigMap with 11 dashboards:

- `vcap-logs`
- `dashboard-node`
- `dashboard-kubernetes`
- `dashboard-loki`
- `dashboard-argocd`
- `dashboard-kirro-lookup`
- `dashboard-kirro-health`
- `dashboard-kirro-infra`
- `dashboard-vcap-dev`
- `dashboard-vcap-staging`
- `dashboard-vcap-metrics`

The vcap and kirro dashboards remain for retained-data support. Their workloads were removed
on 2026-10-23. Most panels are therefore empty or static. Do not delete the dashboards in this
change. They become useful again if a retained dataset is restored for inspection.

The provider polls `/etc/grafana/dashboards`, not ConfigMaps with a `grafana_dashboard=1` label.
A label query returns no dashboards. To inspect the provisioned set, read the generated
ConfigMap:

```bash
kubectl -n monitoring get cm grafana-dashboards-<hash> -o json \
  | jq -r '.data | keys[]'
```

Public dashboards are disabled (`GF_PUBLIC_DASHBOARDS_ENABLED=false`).
Anonymous access is disabled. Basic authentication is enabled. Sign-up is disabled.
The old public dashboard URLs no longer resolve.

## Alerting

Grafana provisions 29 alert rules from `grafana-alerting-rules.yaml`.
Alert state is routed to the Discord contact point `discord-webhook`.
The webhook URL is stored in `k8s/monitoring/secrets.sops.yaml`.

| Area | Rules |
|---|---|
| Node | memory above 85%, CPU above 85%, root filesystem above 80%, inodes above 80%, NotReady |
| Pods | CrashLoopBackOff, OOMKilled, image pull failure |
| Storage | PVC above 85% full |
| TLS | certificate expiring within 60 days |
| ArgoCD | application Degraded, application OutOfSync, login failures |
| KEDA | low-priority workload scaled up from zero |
| Prometheus | scrape target down |
| Loki | no log data for 30 minutes, metrics absent |
| Backups | class A stale after 45 minutes, class C stale after 26 hours, etcd snapshot stale after 36 hours, offsite copy stale after 4 hours, restic check stale after 10 days, restore drill stale after 40 days |
| Backup metrics | absent-metric rules for class A, class C, restic check, restore drill, and etcd snapshot |
| vcap v1 | Postgres authentication failures on the public edge |

The `tls-cert-expiring` rule uses Traefik's loaded-certificate metric:

```promql
(min by (sans) (traefik_tls_certs_not_after) - time()) / 86400 < 60
```

It covers the wildcard certificate. No metric exists for the vcap v1 Postgres edge leaf.
Track that leaf by its recorded expiry date. See [`certificates.md`](certificates.md).

The backup rules read metrics from
`/var/lib/node_exporter/textfile_collector` on the host. No rule depends on healthchecks.io.
In-VM alerting cannot report a powered-off node. That gap remains by design.

## Logs

Loki keeps 168 hours. Promtail ships every pod log. Loki and Promtail are not part of the
backup set. Historical logs are not recoverable after the retention window.

## Related

- [`backups.md`](backups.md): backup timers and thresholds
- [`certificates.md`](certificates.md): certificate inventory
- [`networking.md`](networking.md): public exposure
