# Runbook: VCAP v1 Postgres external access (15434)

How anyone reaches v1's Postgres directly — **no Cloudflare Access, no VPN** — as requested by the
owner on 2026-10-03 while v1 runs in place of the paused v2.

## The contract

| | v1 |
|---|---|
| `host` (for the TLS name) | `pg-v1.upayan.dev` |
| `hostaddr` (what is actually dialled) | `138.201.157.147` (the node's public address) |
| Port | **15434** |
| TLS | required |
| Verification | `sslmode=verify-full` recommended, `verify-ca` the minimum, against the v1 edge CA below |
| Login | `app_user` (the database owner) |

`host` intentionally **has no DNS record** — it is not meant to resolve. It is what libpq puts in
the TLS SNI, which is how Traefik selects this edge's certificate. `hostaddr` is what is dialled.
Creating a record for it would be against this repository's rule that DNS records are adopted from
the live zone rather than hand-written.

### Connecting

```bash
psql "host=pg-v1.upayan.dev hostaddr=138.201.157.147 port=15434 \
      dbname=latex_capstone user=app_user sslmode=verify-full \
      sslrootcert=/path/to/vcap-v1-postgres-edge-ca.crt"
```

Do **not** use `sslmode=require` (it accepts any certificate, so it is not verification) and do not
disable TLS.

TLS is **terminated at the edge** (Traefik), exactly as on v2's path: the client↔edge leg is
encrypted, and Traefik then forwards plaintext TCP to the Postgres pod inside the cluster. So a
session that successfully used `sslmode=verify-full` still reports `ssl = f` in `pg_stat_ssl` — that
column describes the *backend's* connection, not yours. Verified 2026-10-03.

Modern clients (libpq 17+, psql 18) offer the ALPN name `postgresql`; the edge's `TLSOption`
(`vcap-pg` in `vcap-v1`) accepts it. Without that option Traefik answers with alert 120 and the
handshake fails — measured for v2 on 2026-09-29 and unchanged here.

## The CA certificate

Public, and safe to copy from here (it is a certificate, not a key):

```pem
-----BEGIN CERTIFICATE-----
MIIFezCCA2OgAwIBAgIUOcZ1qaLxodwRvailMrnlpnZS0vUwDQYJKoZIhvcNAQEL
BQAwRTEuMCwGA1UEAwwlVkNBUCB2MSBQb3N0Z3JlcyBlZGdlIENBICh1cGF5YW4u
ZGV2KTETMBEGA1UECgwKdXBheWFuLmRldjAeFw0yNjEwMDMxNDA2NDdaFw0zNjA5
MzAxNDA2NDdaMEUxLjAsBgNVBAMMJVZDQVAgdjEgUG9zdGdyZXMgZWRnZSBDQSAo
dXBheWFuLmRldikxEzARBgNVBAoMCnVwYXlhbi5kZXYwggIiMA0GCSqGSIb3DQEB
AQUAA4ICDwAwggIKAoICAQC54SGwyGAaS8VGtR0JNCffhfWuz9tfIMcs066ICRub
NFFx6zLeOYmP3kyFOLH5xwq8Qve08Vx/5XK7eeOGToi+HjCz2l8jeKtzn1NB4pT+
uk5Gfk00MlkmzAdTwN4awyfW8kQdiKjrmIrisxHQJsC2ZaUVP6smQ/D69ay8EIRN
DF5ndl8agnnDdYNT+JtIUIXUGyTeojmXjWhzHNE3eIOgVYIff2A3pIxNf+VYbsEQ
ocJMawsja9ZxJfd687WE0uIpDtImznuH5LVTjiD1MZOPyg9GgLSLmu+H/y+0wjkW
+gBUsJy9/hmnpeHAZTQP3JL/tT9dzF/SK0OIVbJz+sYDct9XrnZV7i/+LkQ8j4jz
OvDA8HCPAJqRopXMH/vH8RUn1UOFokyLPh7BCPczabpSDLlyhPBVS/5nqn5LnmNR
gJPGe6hyVrJLoQsQKIjq/KCdp9DYxVss0EwmPViQ9ndDQg1LIPO+LUPL26CzIuJn
lqCndWjmnEWlMdSdLMqUWt9tmUIektuPx+ojBa1b11Pjqn59NRU/bZKktRHMSonO
XDkAKfUKEiOxn9TZyG5/THfl0izpx5Obv3YERPDfzOiwZTmgJnwTx+R5g9fUpdET
SCOIVSJJ5pyKGGeWqGGSL0wV/0oIetSlrtQj4xwmcHB6dZcz5JZu1vWrmczAaOko
6wIDAQABo2MwYTAdBgNVHQ4EFgQU3O76H6IFcbK39Xo1JJcp+/+ZQiswHwYDVR0j
BBgwFoAU3O76H6IFcbK39Xo1JJcp+/+ZQiswDwYDVR0TAQH/BAUwAwEB/zAOBgNV
HQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggIBADMCZboe/N3z/HOsaId9zfj4
xka8+zw6Glu7WbkEidoB7Hyg4e36uG7/+vtYbBVEaPsnZyNw7HstRoA5QY2YOgRh
qsSTIPvA8LXuaEx5hA8x0Pwa74J3mmxHNNnVUNRFK4vsT9BzZPvBNfIQkwgZkrvU
Ziv2C5gFoVr91Po+GTZSt2AoMzxc9dZ4q5tF8JrvD7KT+KaIPKfux7H+tV3KVxk6
F2lwYJ/94wQbIy0CsfJWUtuvnNEyJPM0g9KTIlCJaMugngUBcbhTfh42k7js8Ffi
B6YSGV88Fd7f69Maiqq4+Ecg8zTjYruGzHLCI98c44LkKbAQzVdYB676S1F5ivK6
4GvryOzwF4Inl4B5hIYfvBY9vKBy58B6XlZGjdEDerXkBYpL4st/aU07udhx5ZiE
f7/YrVncPXBlUUZIb8SPMkTvySb5+0Ewv8KB2q+VsPMkQoBWNiIRDPq0zgcw0Tk0
EIa7HUWReU67Mz5AandYYGB2hjXAKv+ukrIhwug299YdAa54VkUm85oQwsiksDK2
pq4EyCRGctfcpUoJW9Z9RyaNNr5HEToWbbUWtyPkPB+wq0H3STIJkPyI2GQdTNw3
SLA4ua5YhYYNS1GsQ4jkzIhrdo9jYqU6DQK1FioKm2vsvTag+MB5JCvIhuGEregE
3A+ZAcH3GLISLyDVT3NA
-----END CERTIFICATE-----
```

## How this differs from v2's edge, and why

v2's leaves (15432/15433) are signed by the cluster's single `VCAP Postgres edge CA`, whose **key is
deliberately not in this repository** — it is what signs a replacement leaf
(`docs/runbooks/vcap-postgres-access.md`). It is not in the cluster either. So a new leaf **cannot**
be minted under it, and rather than bypass that boundary the v1 edge carries **its own CA**, generated
once on the workstation for this signing operation. The CA certificate is above; the CA key is held by
the owner like the cluster CA's.

The leaf's SANs are `DNS:pg-v1.upayan.dev` and `IP:138.201.157.147`, valid to 2028-10-01 (CA to
2036-09-30). Rotation follows `docs/runbooks/rotate-certificates.md`.

## Security posture — read before relying on this

This path is **world-open on purpose** (owner's instruction): the firewall rule is
`tcp 15434 from 0.0.0.0/0 and ::/0`, with no Cloudflare Access in front, no IP allowlist, and no TLS
client certificate. The only control between the internet and the database is the PostgreSQL password.

Specifically, it **does not** have the mitigations v2's entry lists and gates on: there is no
`pg_hba` restriction, no non-superuser application role, and no per-person read-only roles — v1's
schema and code expect `app_user` to own the database, so those changes would break the
application, not just narrow the edge. `inventory/ports.yaml`'s 15434 entry records the same.

To narrow it: remove or scope the firewall rule in `terraform/firewall.tf` and apply, and/or delete
the `IngressRouteTCP` — both are reviewed changes, not prune sweeps (`Prune=false` on the route).
