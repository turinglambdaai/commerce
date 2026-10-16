# ADR-0002: Pure default facade and explicit server capabilities

Status: accepted, 2026-10-16

## Context

Products need stable commercial values and perhaps a thin online client.
Provider adapters and the Commerce service need secrets, raw webhook parsing,
network listeners, persistence, and Permit issuer access. A convenient umbrella
module would make it easy to use server-only powers in the wrong process.

## Decision

`(require commerce)` exports only pure domain values, read access to verified
event fields, immutable projections, and deterministic transitions.

`(require commerce/provider)` is an explicit server-side boundary and owns the
constructor for verified canonical payment events. Future network, persistence,
and Permit issuer modules remain explicit and are not re-exported by the default
facade.

## Consequences

- A product cannot accidentally accept raw payment claims by importing the
  default package.
- Documentation must clearly identify server-side modules.
- Provider implementers write one extra explicit require, which is desirable
  friction at a trust boundary.

