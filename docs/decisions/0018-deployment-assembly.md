# ADR-0018: Deployment assembly

- Status: Accepted
- Date: 2026-10-22

## Context

The boundaries were complete and headless, but "how does this become a
running service" lived in the reader's head. A deployment answer was
needed that adds no second brain and keeps every durability invariant.

## Decision

`examples/service.rkt` is the canonical assembly: one process runs the
HTTP edge (webhooks, claim portal, `/readyz`), a projector/worker loop
(drain the projection, then drive issuance until idle), and one SQLite
store. Configuration is environment-only; secrets are injected as file
paths read once at startup. The Offer/policy catalog stays compiled
into the service as reviewed configuration.

Termination is deliberately boring: SIGTERM/SIGKILL ends the process
with no signal handler, because the store is crash-safe by design —
WAL with full sync, lease expiry reclaim, and projection replay from
the immutable journal make any restart converge. A clean in-process
shutdown path exists via the stop semaphore.

`deploy/` carries the two supported runners: a hardened systemd unit
(protected system, single writable database directory) and a Docker
image with a `/data` volume. TLS termination, rate limiting, and log
shipping remain external, as every prior decision states.

## Consequences

- The path from `raco pkg install` to a running, restart-safe service
  is documented and copyable without weakening any boundary.
- Readiness is now observable over HTTP (`/readyz`), closing the
  operations loop for load balancers and supervisors.
- Scaling story is unchanged and honest: one SQLite node per service
  instance; horizontal scaling is a future store decision, not a
  deployment afterthought.
