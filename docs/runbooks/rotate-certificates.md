# Runbook: rotate a certificate

Two TLS Secrets are live on 2026-10-27:

- `kube-system/wildcard-upayan-dev-tls` — Cloudflare Origin CA wildcard for every `*.upayan.dev`
  host.
- `kube-system/k3s-serving` — the k3s API server certificate. The k3s install manages it.

This runbook covers the wildcard. Design background:
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
for h in argocd.upayan.dev ks.upayan.dev status-page.upayan.dev grafana.upayan.dev; do
  printf '%-30s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' "https://$h")"
done
```

Expected: `302`, `200`, `200`, `302`. A `526` means Cloudflare cannot validate the origin
certificate. Fix the Secret or the key pair before you continue.

### 5. Verify the origin serves the new certificate

```bash
echo | openssl s_client -connect 138.201.157.147:443 -servername argocd.upayan.dev 2>/dev/null \
  | openssl x509 -noout -serial -dates -ext subjectAltName
```

Expected: the new serial and both SANs. A direct origin probe from a workstation can fail because
of the network path. If it does, read the certificate from the live Secret instead and use the
public hostname checks above as the serving proof.

### 6. Revoke the old certificate

Revoke the old serial only after the new certificate serves traffic. If you revoke first,
Cloudflare rejects the origin certificate.

## v1 Postgres edge leaf (retired 2026-10-27)

The `vcap-v1` Postgres edge no longer exists. Do not rotate its certificate. Nothing serves it.

- The IngressRouteTCP `vcap-v1-postgres`, the TLSOption `vcap-pg`, and the entrypoint `vcap-pg-v1`
  (TCP 15434) are removed.
- The firewall rule for TCP 15434 is removed. The port is closed.
- The leaf Secret `vcap-v1/vcap-v1-postgres-edge-tls` remains in the namespace as retained data.
  No workload uses it. It expires 2031-10-02.

To read the retained data, see Variant A in [`restore-postgres.md`](restore-postgres.md).
