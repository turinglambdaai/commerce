# Contributing to Commerce

Commerce handles payment-adjacent and product-rights state, so changes favor
small auditable slices over broad convenience APIs.

## Start here

1. Read `AGENTS.md`, `docs/architecture.md`, `docs/security.md`, and the first
   unchecked slice in `ROADMAP.md`.
2. Read the contract for the boundary being changed: `docs/provider-contract.md`
   for provider input, `docs/permit-integration.md` for issuance, or
   `docs/family-integration.md` for repository ownership.
3. Add a characterization or failing regression test before changing behavior.
4. Keep one event/journal/projection/outbox/issuer/delivery boundary per change.

## Required checks

```bash
raco make commerce/main.rkt commerce/provider.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
raco scribble --htmls --dest <temporary-directory> \
  commerce-doc/scribblings/commerce.scrbl
git diff --check
```

Persistence and serialization changes also require inspection of emitted rows
or artifacts. Provider changes require captured valid and invalid fixtures.
Never treat source matching or a mocked happy path as production evidence.

## Pull requests

Explain the invariant, failure mode, compatibility effect, and concrete
evidence. Update the canonical document and both English and Chinese entry
documentation when the user path changes. Do not mix a provider adapter,
storage migration, Permit semantic change, and product UI change in one pull
request.

Never commit production provider secrets, signing keys, payment data, customer
exports, or claim tokens. Test material must be deterministic, clearly marked,
and contain no real personal data.

## Documentation languages

Use English for default public docs and preserve complete Chinese README and onboarding paths. Keep examples, supported-platform limits, troubleshooting and privacy/security promises consistent in the same change. Preserve identifiers and copyable commands; technical protocols have one normative English source, not separate language implementations. See the [family documentation language policy](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md) for scope and review checks.
