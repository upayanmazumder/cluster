# Certificates and TLS

TLS terminates on Traefik. The default certificate is a Cloudflare Origin CA wildcard. Ingresses do
not declare `tls:`. No ACME client or cert-manager is installed.

## Live TLS Secrets

Exactly three `kubernetes.io/tls` Secrets exist:

| Namespace / Secret | Purpose |
|---|---|
| `kube-system/k3s-serving` | k3s API server certificate. The cluster manages it. |
| `kube-system/wildcard-upayan-dev-tls` | Traefik default certificate for `*.upayan.dev`. |
| `vcap-v1/vcap-v1-postgres-edge-tls` | Postgres edge leaf and private CA for `pg-v1.upayan.dev`. |

`TLSStore default` in `kube-system` points at `wildcard-upayan-dev-tls`. Every Ingress uses it.

The v1 Postgres edge Secret is a live exception to the "no per-app TLS Secret" rule. The edge is a
TCP router, not an Ingress. It needs its own SNI certificate.

The old v2 Postgres edge Secret and the v2 host `db.upayan.dev` are gone. The old v2 entrypoints on
TCP `15432` and `15433` were removed on 2026-10-23.

## Wildcard certificate

Observed from the live Secret on 2026-10-23:

```
serial   699090E41816073595D26CDDE0568CFE6C66BCB7
notBefore Sep 28 12:35:00 2026 GMT
notAfter  Sep 28 12:35:00 2027 GMT
subject   O=CloudFlare, Inc., OU=CloudFlare Origin CA, CN=CloudFlare Origin Certificate
SAN       DNS:*.upayan.dev, DNS:vps.upayan.dev
```

The certificate is valid for one year. Cloudflare does not renew an Origin CA certificate. Renew it
before 2027-09-28. The procedure is in
[`runbooks/rotate-certificates.md`](runbooks/rotate-certificates.md).

The previous 2041 certificate was revoked on 2026-09-28. It is not in use. The current keypair was
generated fresh and was never committed. The current certificate exists only in the SOPS-encrypted
Secret.

Do not probe the origin directly from the workstation. That probe fails and does not prove the live
certificate. Read the live Secret, or test a public host.

Public checks that answer:

| Host | Expected |
|---|---|
| `vcap.upayan.dev` | `200` |
| `argocd.upayan.dev` | `302` |
| `ks.upayan.dev` | `200` |
| `status-page.upayan.dev` | `200` |
| `grafana.upayan.dev` | `302` |

`api-vcap.upayan.dev` and `api.upayan.dev` return `404` at the root. That is not a TLS failure.

Read the loaded certificate:

```bash
kubectl -n kube-system get secret wildcard-upayan-dev-tls \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -serial -dates -subject -ext subjectAltName
```

## v1 Postgres edge

Observed from `vcap-v1/vcap-v1-postgres-edge-tls` on 2026-10-23:

```
serial   26E4887722DD06E9D520F2B3B839D75E164EF504
notBefore Oct  3 14:06:48 2026 GMT
notAfter  Oct  2 14:06:48 2031 GMT
subject   CN=pg-v1.upayan.dev, O=upayan.dev
issuer    CN=VCAP v1 Postgres edge CA (upayan.dev), O=upayan.dev
SAN       DNS:pg-v1.upayan.dev, IP Address:138.201.157.147
```

The embedded CA expires on 2036-09-30. The leaf expires on 2031-10-02.

- **Host:** `pg-v1.upayan.dev`, DNS-only in Cloudflare.
- **Port:** TCP `15434`, open to all sources.
- **SNI:** `pg-v1.upayan.dev`.
- **Backend:** `vcap-backend-v1-postgres:5432`.
- **TLSOption:** `vcap-pg`.
- **Client mode:** `sslmode=verify-full` with the CA certificate.

Read the live leaf:

```bash
kubectl -n vcap-v1 get secret vcap-v1-postgres-edge-tls \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -serial -dates -subject -issuer -ext subjectAltName
```

The v1 edge leaf is valid for five years. Rotation is owner-gated. See
[`runbooks/vcap-v1-postgres-access.md`](runbooks/vcap-v1-postgres-access.md).

## Expiry monitoring

| Scope | Metric | Alert |
|---|---|---|
| Wildcard, all Ingress hosts | `traefik_tls_certs_not_after` | `tls-cert-expiring`, fires below 60 days |
| v1 Postgres edge | none | no metric exists |

The wildcard rule is live. Its query:

```promql
(min by (sans) (traefik_tls_certs_not_after) - time()) / 86400 < 60
```

`vcap_db_cert_expiry_timestamp` does not exist. No vcap edge certificate metric exists. The v1 leaf
expiry is a calendar item for the owner. It is not monitored.

## Two-level hostnames

Cloudflare Universal SSL covers one wildcard level. A host such as `x.y.upayan.dev` fails at the
Cloudflare edge, before traffic reaches the origin. Use single-level, hyphenated hostnames. The
current vcap hosts follow that rule.

## Historical notes

- cert-manager was removed on 2026-09-28.
- The six broken per-app Ingress `tls:` references were removed on 2026-09-28.
- The cluster went from 22 TLS Secrets to two. The v1 edge Secret was added later.
- The 2026-05-10 Origin certificate had a committed key. It was revoked on 2026-09-28.
- The 2025 Origin certificate was not active. There was nothing to revoke.
- Older docs said the wildcard expired in 2041. That was the superseded certificate.

## Related

- [`runbooks/rotate-certificates.md`](runbooks/rotate-certificates.md): reissue procedure.
- [`runbooks/vcap-v1-postgres-access.md`](runbooks/vcap-v1-postgres-access.md): v1 edge access.
- [`secrets.md`](secrets.md): SOPS policy.
- [`networking.md`](networking.md): public Postgres design.
