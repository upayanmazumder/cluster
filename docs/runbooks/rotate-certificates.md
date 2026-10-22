# Runbook: rotate a certificate

Three TLS Secrets are live on 2026-10-23:

- `kube-system/wildcard-upayan-dev-tls` — Cloudflare Origin CA wildcard for every `*.upayan.dev`
  host.
- `kube-system/k3s-serving` — the k3s API server certificate. The k3s install manages it.
- `vcap-v1/vcap-v1-postgres-edge-tls` — the private-CA leaf for the v1 Postgres edge.

This runbook covers the wildcard and the v1 Postgres edge. Design background:
[`../certificates.md`](../certificates.md).

## Cloudflare Origin CA wildcard

**Current certificate, read from the live Secret:**

- Serial `699090E41816073595D26CDDE0568CFE6C66BCB7`.
- SANs `DNS:*.upayan.dev, DNS:vps.upayan.dev`.
- Valid 2026-09-28 → 2027-09-28.

`TLSStore default` in `kube-system` points at this Secret. The Secret is SOPS-encrypted in
`k8s/platform/traefik/secrets.sops.yaml` and applied by the ksops generator
`k8s/platform/traefik/secret-generator.yaml`.

Nothing renews this certificate automatically. The Grafana rule `tls-cert-expiring` alerts when a
loaded Traefik certificate expires in less than 60 days. The rule queries
`traefik_tls_certs_not_after`. It exists and runs.

> **Renew before 2027-09-28.**

The `034BB255…` certificate named by older documents is a predecessor. It was valid to 2041 and is
revoked. Its private key was public in git history from 2026-05-10 until 2026-09-28. That is why the
2026-09-28 rotation used a fresh key and revoked the old certificate.

### 1. Issue a new certificate with a new key

Dashboard: **SSL/TLS → Origin Server → Create Certificate**. Use hostnames `*.upayan.dev` **and**
`vps.upayan.dev`. Keep the key on the machine that will run `sops`.

Request one year of validity, not the old 15-year term.

Via the API, use a token with **Origin CA: Edit**:

```bash
POST https://api.cloudflare.com/client/v4/certificates
Authorization: Bearer <token>
{"hostnames":["*.upayan.dev","vps.upayan.dev"],"requested_validity":365,"request_type":"origin-rsa","csr":"<PEM CSR text>"}
```

Two API details matter:

- The `csr` field takes the PEM text, not base64 DER. Base64 DER returns
  `1007 CSR parsed as empty`.
- List and revoke are zone-scoped. Use `GET /certificates?zone_id=…` and
  `DELETE /certificates/<id>?zone_id=…` with the full 47-character id.

### 2. Store it

```bash
sops k8s/platform/traefik/secrets.sops.yaml
```

Update the `tls.crt` and `tls.key` values in Secret `wildcard-upayan-dev-tls`. The Secret lives in
`kube-system`. There is no separate origin-certificate file.

### 3. Commit, push, sync

```bash
git add k8s/platform/traefik/secrets.sops.yaml
git commit -m "rotate: Cloudflare Origin CA wildcard (new key)"
git push origin main
kubectl -n argocd annotate app traefik-config argocd.argoproj.io/refresh=hard --overwrite
```

### 4. Restart Traefik and confirm only the new certificate is loaded

Traefik's certificate store is additive. Replacing the Secret adds the new leaf. It does not drop
the leaf already in memory. A revoked predecessor stays loaded and can still serve until Traefik
restarts.

```bash
kubectl -n kube-system rollout restart deploy/traefik
kubectl -n kube-system rollout status  deploy/traefik --timeout=180s
```

This is a permitted break-glass action after a Secret change. Traefik is a single replica. Nothing
listens on ports 80 and 443 for a few seconds.

Confirm exactly one certificate is loaded:

```bash
kubectl -n monitoring exec deploy/prometheus -c prometheus -- \
  wget -qO- --post-data='query=min by (serial) (traefik_tls_certs_not_after)' \
  http://localhost:9090/api/v1/query | python3 -m json.tool | grep -E 'serial|value'
```

Expected: one series with the new serial. Two series mean the old leaf is still loaded. No series
means Traefik is not exporting certificate metrics.

Use `min by (serial)`. Traefik exports one series per loaded certificate. Prometheus scrapes the pod
twice, so the bare metric returns duplicates.

Check public hosts:

```bash
for h in vcap.upayan.dev argocd.upayan.dev ks.upayan.dev status-page.upayan.dev grafana.upayan.dev; do
  printf '%-30s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' "https://$h")"
done
```

Expected: `200`, `302`, `200`, `200`, `302`. A `526` means Cloudflare cannot validate the origin
certificate. Fix the Secret or the key pair before you continue.

### 5. Verify the origin serves the new certificate

```bash
echo | openssl s_client -connect 138.201.157.147:443 -servername vcap.upayan.dev 2>/dev/null \
  | openssl x509 -noout -serial -dates -ext subjectAltName
```

Expected: the new serial and both SANs. A direct origin probe from a workstation can fail because
of the network path. If it does, read the certificate from the live Secret instead and use the
public hostname checks above as the serving proof.

### 6. Revoke the old certificate

Revoke the old serial only after the new certificate serves traffic. If you revoke first,
Cloudflare rejects the origin certificate.

## v1 Postgres edge leaf

The `vcap-v1` Postgres edge is live. It is not planned work.

| Item | Live value |
|---|---|
| Secret | `vcap-v1/vcap-v1-postgres-edge-tls` |
| Keys | `tls.crt` (leaf), `tls.key`, `ca.crt` (self-signed CA) |
| Source | `k8s/apps/vcap-v1/edge/secrets.sops.yaml` |
| Route | IngressRouteTCP `vcap-v1/vcap-v1-postgres` |
| Entrypoint | `vcap-pg-v1`, TCP `15434` |
| SNI | `pg-v1.upayan.dev` |
| Backend | `vcap-backend-v1-postgres:5432` |
| Leaf serial | `26E4887722DD06E9D520F2B3B839D75E164EF504` |
| Leaf validity | 2026-10-03 → **2031-10-02** |
| CA validity | to 2036-09-30 |
| Leaf SANs | `DNS:pg-v1.upayan.dev`, `IP:138.201.157.147` |
| TLSOption | `vcap-pg` |

`pg-v1.upayan.dev` has no DNS record by design. Clients pass `host=pg-v1.upayan.dev` for SNI and
certificate verification. They pass `hostaddr=138.201.157.147` to dial the server.

The CA private key is not stored in the cluster. The Secret holds only the leaf, the leaf key, and
the CA certificate. Keep the CA private key offline. If it is lost, mint a new CA and distribute the
new `ca.crt` to every client.

### 1. Mint a new leaf

Use the existing edge CA. Do not regenerate the CA. A new CA invalidates every client's
`sslrootcert`.

```bash
openssl req -new -newkey rsa:2048 -nodes \
  -keyout pg-v1.key -out pg-v1.csr \
  -subj "/CN=pg-v1.upayan.dev/O=upayan.dev"
openssl x509 -req -in pg-v1.csr -CA vcap-v1-edge-ca.crt -CAkey vcap-v1-edge-ca.key \
  -CAcreateserial -out pg-v1.crt -days 1825 -sha256 \
  -extfile <(printf 'subjectAltName=DNS:pg-v1.upayan.dev,IP:138.201.157.147\nextendedKeyUsage=serverAuth\n')
```

Set `-days` so the leaf stays inside the CA lifetime. The current CA expires on 2036-09-30.

### 2. Store it

```bash
sops k8s/apps/vcap-v1/edge/secrets.sops.yaml
```

Replace the base64 `tls.crt`, `tls.key`, and `ca.crt` values. Keep the Secret name and keys
unchanged. The IngressRouteTCP selects the Secret by name.

### 3. Commit, push, sync

```bash
git add k8s/apps/vcap-v1/edge/secrets.sops.yaml
git commit -m "rotate: vcap v1 Postgres edge leaf"
git push origin main
kubectl -n argocd annotate app vcap-v1 argocd.argoproj.io/refresh=hard --overwrite
```

Restart Traefik after the Secret changes. Traefik is additive and does not drop the old leaf:

```bash
kubectl -n kube-system rollout restart deploy/traefik
kubectl -n kube-system rollout status  deploy/traefik --timeout=180s
```

### 4. Verify

Read the served leaf:

```bash
openssl s_client -connect 138.201.157.147:15434 -servername pg-v1.upayan.dev \
  -CAfile vcap-v1-edge-ca.crt </dev/null 2>/dev/null \
  | openssl x509 -noout -serial -dates -subject -issuer -ext subjectAltName
```

Check a real connection:

```bash
psql "host=pg-v1.upayan.dev hostaddr=138.201.157.147 port=15434 \
  dbname=latex_capstone user=app_user sslmode=verify-full \
  sslrootcert=vcap-v1-edge-ca.crt" -c '\conninfo'
```

The edge is reachable from the public internet. The Postgres password is the only access control.
Do not expose recovered data through this edge.

### 5. Expiry monitoring gap

No metric reports the v1 edge certificate expiry. `vcap_db_cert_expiry_timestamp` does not exist.
The wildcard rule `tls-cert-expiring` covers only certificates that Traefik loads from the
`TLSStore`. It does not cover the per-route v1 edge certificate.

Track the leaf expiry by hand. The next rotation is due before 2031-10-02. If you add a metric,
make it query the leaf's `notAfter` and alert 60 days before expiry.
