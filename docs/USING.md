# Commerce adoption and support

**English** · [简体中文](USING.zh-CN.md)

## When to use it

Use Commerce only when a product needs durable payment-to-rights orchestration. It is one headless service with explicit provider and Permit issuer boundaries; it is not a payment processor, merchant of record, identity system or proof of merchant eligibility.

## Requirements and maturity

Racket CS 9.0+ and deployment dependencies from the runbook. The first provider path is Pancake; fixtures and a running SQLite process do not establish live checkout, settlement or regulatory readiness. Product/merchant approval is a separate launch gate.

## One useful verification

Run the mock walkthrough before configuring provider secrets. For real operation authenticate exact webhook bytes, durably journal them, project in a transaction and issue from the outbox. A checkout redirect is not payment evidence. Backup/restore must include the SQLite journal/projection/outbox and separately protected signer material; never replay unknown outcomes by guesswork.

## Reading path

1. [Mock first purchase](getting-started.md)
2. [Documentation map](README.md)
3. [Provider contract](provider-contract.md)
4. [Security boundary](security.md)
5. [Architecture](architecture.md)

Technical references retain one normative meaning. Chinese onboarding explains and links to that reference rather than creating a second protocol.

## Upgrades, data and support

Record the package versions and platforms your application actually tests. Read CHANGELOG and compatibility contracts before upgrading, test user-data migration on copies and retain a recoverable version. A library does not supply your product’s database backup, publisher identity, refunds, account recovery or privacy policy. Example customer/offer identifiers and amounts are fixtures, not live offers.

Use [Issues](https://github.com/turlamai/commerce/issues) in English or Chinese. Include package/commit, Racket version, OS/architecture, a minimal reproduction and the first redacted error. Never attach real keys, customer credentials, raw payment data or private documents. Community support has no guaranteed response time.

[Security boundaries](security.md) cover service secrets and data handling; public issues must use non-sensitive reproductions.

[Current licence](../LICENSE) · [CHANGELOG](../CHANGELOG.md)
