# Security policy

## Private vulnerability reporting

Use [GitHub private vulnerability reporting](https://github.com/turlamai/commerce/security/advisories/new) if it is enabled for this repository. If private reporting is unavailable, contact the repository owner privately to arrange a confidential channel **without sharing exploit details in a public issue**. Ordinary defects without security implications belong in [Issues](https://github.com/turlamai/commerce/issues).

Include the affected commit/version and boundary, a minimal **synthetic/redacted** reproduction, observed and expected behavior, potential impact, and whether secrets or data could have been exposed. Never submit real provider API keys, Permit private keys, customer data, payment payloads or claim tokens. Do not create live payment events while investigating. No response or remediation SLA is promised.

## Supported scope and trust model

The latest `main` revision is the current development target. A release support policy must be recorded before promising support for any tagged version. The [security model](docs/security.md), [provider contract](docs/provider-contract.md), [Permit integration](docs/permit-integration.md), and [split-role ADR](docs/decisions/0020-split-service-roles.md) are the normative technical references.

Security-sensitive boundaries include:

- Exact-byte webhook authenticity, environment binding, active provider-order proof, replay/conflict handling and cost/amount integrity.
- Subject identity binding, entitlement lineage, one-time claim tokens and redacted audit logs.
- SQLite filesystem permissions, backups/restores, and outbox authorization; **separate processes sharing a writable database do not provide a complete signer authorization boundary**.
- Distinct provider, Permit signing, update-signing and publishing keys, least privilege, rotation and compromise recovery.

## Production status

Fixtures, green CI and split-role deployment are not proof of merchant approval or secure live issuance. The outstanding security boundary and operational launch gates are tracked in [release evidence](docs/release-checklist.md), [Commerce #10](https://github.com/turlamai/commerce/issues/10), [#5](https://github.com/turlamai/commerce/issues/5) and [#4](https://github.com/turlamai/commerce/issues/4). Do not classify a mock checkout as a live purchase or put a production signing key into the HTTP edge.
