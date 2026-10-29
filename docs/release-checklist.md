# Commerce release evidence and go-live gates

**Status: not a production-readiness certificate.** A green test suite, simulated checkout, or successful container build cannot substitute for verified provider eligibility, a trustworthy signer boundary, or an approved live purchase. Track issues [#10](https://github.com/turlamai/commerce/issues/10), [#5](https://github.com/turlamai/commerce/issues/5), [#4](https://github.com/turlamai/commerce/issues/4) separately.

This is the single place to record *release evidence requirements*, not a duplicate of protocol contracts. Definitions and threat models live in [security](security.md), [provider contract](provider-contract.md), [Permit integration](permit-integration.md), [operations](operations.md), [runbook](runbook.md), [deployment](../deploy/README.md), and [ADR-0020](decisions/0020-split-service-roles.md).

## 1. Candidate identity and reproducibility

- [ ] Record the exact Commerce candidate commit, Racket version(s), Permit source commit, Docker image digest and base-image digest. Never use a floating dependency for an audited production build.
- [ ] Run and archive the full GitHub Actions CI result on the **candidate merge commit**, not only a PR branch. Check Windows, Ubuntu, macOS (both supported Racket versions), package dependency validation, Scribble, Docker build and the latest-Permit compatibility lane. Queued, skipped or cancelled jobs are not passes.
- [ ] Review user-facing change notes, English/Chinese quick starts, API/CLI examples, migration compatibility and package-install instructions. Confirm each command from a clean checkout.
- [ ] Rehearse deployment from a pinned artifact and a tested rollback; identify the owner who can stop a rollout. Record where evidence is kept **without** embedding private data in Git.

## 2. Signer and customer-rights boundary — blocker #10

- [ ] Verify separate OS identities, actual filesystem permissions and key-purpose segregation; the HTTP edge cannot read Permit private keys.
- [ ] Address the outstanding **shared writable SQLite database** authorization risk with independently authenticated signing intents or an equally reviewed, unforgeable evidence path. Splitting processes alone is insufficient.
- [ ] Reject test/production confusion, an unknown issuer/key/policy, unsigned or tampered evidence, a fixture offer used for production, and an unauthorized subject change.
- [ ] Exercise signer outage, retry, lease expiry/loss, crash after signing but before commit, duplicate and delayed events, refund or chargeback, and key rotation. Confirm no extra charge or unintended lineage revision.
- [ ] Audit logs and diagnostic formatting for accidental private key, token, personal-data and provider-secret disclosure; verify an encrypted-backup restore and separation of duty.

## 3. Provider admission and real transaction — blockers #5 and #4

- [ ] Obtain explicit merchant/product approval and verify the **current** allowed payment method, currency, transaction type, amount limits, refund support, fees, tax/settlement responsibilities and payout path. Fixture adapters are not approval.
- [ ] Confirm the verified checkout-creation and active order-read APIs for the account **before** presenting a live checkout. Never infer method acceptance from payout method availability.
- [ ] Obtain authorization for an actual low-value test purchase; retain redacted provider-side transaction and settlement identifiers privately. Do not initiate a charge, refund or merchant onboarding from an automated agent without explicit approval.
- [ ] Record the successful verified payment → durable journal → projected order → **exact subject/offer/amount** → signed Permit credential → claim → offline import → update-window eligibility. Include provider mode, timestamps, candidate SHAs and redacted operator evidence.
- [ ] Rehearse delayed/duplicate webhook, missing browser return, payment-unknown timeout, failed claim/import, cancellation/refund and operator recovery without a second charge. Confirm the refund outcome honestly reflects offline revocation limits.
- [ ] Verify payout/FX/refund costs separately from provider-paid and bank-settled states.

## 4. Documentation, privacy and incident response

- [ ] Confirm the [private vulnerability report path](../SECURITY.md) is available and no public PR or issue contains raw secrets or payment data.
- [ ] Confirm retention, user-data export/deletion, backups, access control, disaster recovery, merchant support handoff and customer-facing contact/recovery paths are documented and rehearsed.
- [ ] Capture an explicit go/no-go decision signed off by the responsible human operator. If any #10/#5/#4 blocker remains, mark **NO-GO** for valuable live issuance.

## Release record template (store evidence outside the repository)

| Field | Value |
| --- | --- |
| Commerce commit / Permit commit | Not recorded |
| Candidate CI run links and full conclusion | Not recorded |
| Environment / merchant admission approval | Not recorded |
| Signer boundary review and backup/restore evidence | Not recorded |
| Live purchase + claim/import evidence (redacted link only) | Not recorded |
| Rollback image digest / migration recovery test | Not recorded |
| Human go/no-go owner and decision | **NO-GO until all blockers are verified** |

Never turn an unchecked item into a success claim because its corresponding implementation or a mock example exists. The owner must attach reproducible evidence before ticking it.
