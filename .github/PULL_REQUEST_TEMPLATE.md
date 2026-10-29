## Problem and bounded scope

<!-- Describe the failure mode, invariant protected and why Commerce owns the change. Link an issue/ADR. -->

## Contracts and compatibility

<!-- Identify changed public facade, provider, journal, storage schema, issuer, claim, CLI or deployment behavior; include migration/rollback impact. -->

## Verification evidence

- [ ] Focused red/green regression test demonstrates the failure boundary.
- [ ] `raco test -p commerce` (or explain what was not run).
- [ ] `raco setup --check-pkg-deps commerce`, compile/Scribble checks (or explain).
- [ ] CI matrix reviewed for Racket 9.0/9.3 on Windows, Ubuntu and macOS, plus Docker/quality/Permit compatibility; no queued/failed checks represented as green.
- [ ] Markdown links, `CHANGELOG.md`, canonical ADR/contract and English/Chinese entry paths reviewed where affected.
- [ ] No production secrets, personal data, raw payment payloads, or reusable claim tokens committed or pasted into PR/CI logs.

## Trust, recovery and agent handoff

<!-- For event or issuance changes: document duplicate/reorder/retry/crash/unknown outcome behavior, subject binding and exact evidence artifacts. For docs-only changes: say not applicable. -->

**Base / head SHA:**

**Commands actually run and outcomes (not just intended):**

**Remaining risks / unverified external gates:**

<!-- Mocked success is not merchant admission (#5), production signer isolation (#10), or a live purchase (#4). Do not merge by bypassing required platform checks. -->
