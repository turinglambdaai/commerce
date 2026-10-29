# Deploying Commerce

Commerce ships as a Racket package. A deployment is one process that
assembles the boundaries — HTTP edge, projector, issuer worker — over
one SQLite store. `examples/service.rkt` is that assembly; this
directory holds the two supported ways to run it. TLS termination,
rate limiting, and log shipping stay with your reverse proxy and
infrastructure (see `docs/runbook.md`).

## Configuration

Everything arrives through the environment; secrets are file paths read
once at startup (mode 0600, never committed).

| Variable | Meaning | Default |
| --- | --- | --- |
| `COMMERCE_DB_PATH` | SQLite store path (writable) | required |
| `COMMERCE_PORT` / `COMMERCE_LISTEN_IP` | HTTP bind | 8080 / 127.0.0.1 |
| `COMMERCE_POLL_SECONDS` | Worker loop poll interval | 2 |
| `COMMERCE_ENVIRONMENT` | `test` or `production`; locks the keyring and merchant reads | `test` |
| `COMMERCE_ISSUER` | Permit issuer identity | required |
| `COMMERCE_WORKER_OWNER` | Outbox lease owner label | `commerce-service` |
| `PERMIT_KEY_ID` | Active trust-store key id | required |
| `PERMIT_PRIVATE_KEY_PATH` | Ed25519 signing key (PEM) | required |
| `PERMIT_TRUST_STORE_PATH` | Permit trust store (JSON) | required |
| `PANCAKE_MERCHANT_ID` | Pancake merchant id | required |
| `PANCAKE_MERCHANT_KEY_PATH` | Pancake merchant RSA key (PEM) | required |
| `PANCAKE_WEBHOOK_TEST_KEY_PATH` | Pancake test webhook public key (PEM) | required |
| `PANCAKE_WEBHOOK_PRODUCTION_KEY_PATH` | Pancake production webhook public key (PEM) | required |

The Offer/policy catalog is compiled into the service
(`examples/service.rkt` carries a placeholder) — it is code-reviewed
configuration, per `docs/permit-integration.md`.

## systemd

```bash
sudo useradd -r -s /usr/sbin/nologin commerce
sudo mkdir -p /opt/commerce /var/lib/commerce /etc/commerce
sudo cp -r . /opt/commerce
sudo cp deploy/commerce.service /etc/systemd/system/
# install racket 9.3 at /usr/bin/racket (or adjust ExecStart)
# provision /etc/commerce/* secrets (mode 0600, owner commerce)
sudo systemctl daemon-reload
sudo systemctl enable --now commerce
curl -s http://127.0.0.1:8080/readyz | jq
```

`SIGTERM` from `systemctl stop` terminates the process; the store is
crash-safe by design (WAL, full sync, lease reclaim on restart), so no
signal handler is required for correctness.

## Docker

The Dockerfile pins Permit to `ed32d0eec463665e470657e54d222a1b98148a1e`, the same revision as CI.
The default Racket base image is a mutable tag suitable only for development.
For a release, select and independently verify an image digest, then pass
`--build-arg RACKET_IMAGE=racket/racket@sha256:<verified-digest>`.
Record Commerce SHA, Permit SHA, Racket base image digest, produced image digest,
and a tested rollback image in the deployment manifest. A missing base digest
is still an explicit production release gate; it must not be guessed.

```bash
docker build -t commerce-service -f deploy/Dockerfile .
docker run -d --name commerce \
  -p 127.0.0.1:8080:8080 \
  -v commerce-data:/data \
  --env-file deploy/commerce.env \
  commerce-service
curl -s http://127.0.0.1:8080/readyz
```

Provide the secret paths inside `deploy/commerce.env` as paths that
exist inside the container (mount them read-only, e.g.
`-v $PWD/secrets:/run/secrets:ro`).

## Endpoints

- `POST /webhooks/pancake` — provider webhook ingress (exact-byte
  authentication, active order verification, idempotent journaling).
- `POST /claims` — one-time claim fulfillment (token in, signed Permit
  envelope out; 404/409/410 for unknown, reused, expired).
- `GET /readyz` — readiness snapshot; 503 with typed warnings when
  stuck work needs an operator.

## Before production

1. Replace the placeholder catalog with your reviewed policies.
2. Rehearse backup/restore (`docs/runbook.md`) with the live store.
3. Point TLS termination at the service and rate-limit `/claims` and
   `/webhooks/pancake`.
4. Rehearse key rotation (`docs/runbook.md`).
5. Ship the `commerce` log topic as JSON lines.
