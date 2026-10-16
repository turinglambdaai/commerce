# Getting started

This guide takes a new contributor from an empty Racket installation to one
audited purchase transition. It uses the mock boundary deliberately: no account,
secret, network access, or real payment is required.

## 1. Requirements

- Racket CS 9.0 or newer
- Git

## 2. Install a linked checkout

```bash
git clone https://github.com/turinglambdaai/commerce.git
cd commerce
raco pkg install --auto --no-docs --name commerce .
```

The package contains multiple collections. Product-safe code starts with:

```racket
(require commerce)
```

Provider adapters explicitly add:

```racket
(require commerce/provider)
```

Services that durably accept authenticated events explicitly add:

```racket
(require commerce/journal
         commerce/journal/sqlite)
```

## 3. Run the first purchase

```bash
racket examples/first-purchase.rkt
```

The walkthrough constructs a payment event as though a mock adapter had already
authenticated it, then applies it to an immutable state. One `grant` rights
intent is emitted. Replaying the same provider event is acknowledged without
emitting a second intent.

## 4. Read the test before changing behavior

```bash
raco test commerce-test/core-test.rkt commerce-test/journal-test.rkt
```

The tests show the intended answers to the first difficult questions:

- What happens when a provider retries the same webhook?
- What happens when an event id is reused with different content?
- What happens when a refund notification arrives before the payment event?
- What prevents two success notifications from granting twice?
- What happens when amount or offer identity changes for the same order?
- What proves acknowledgement survives a service restart?
- What database row is emitted, and can ordinary SQL mutate it?

## 5. Understand the boundary

Read these in order:

1. [Concepts](concepts.md)
2. [Architecture](architecture.md)
3. [Provider contract](provider-contract.md)
4. [Permit integration](permit-integration.md)
5. [Security](security.md)

Do not begin a real provider adapter from its happy-path SDK example. Capture
its authentication scheme, retry behavior, query API, refund semantics, test
mode, and fixture evidence in the provider contract first.

## 6. Run the full gate

```bash
raco make commerce/main.rkt commerce/provider.rkt commerce/journal.rkt \
  commerce/journal/sqlite.rkt \
  commerce-doc/scribblings/commerce.scrbl
raco test -p commerce
raco setup --check-pkg-deps commerce
```

The first production provider is Pancake. Its implementation begins only after
M1 acceptance criteria in [ROADMAP.md](../ROADMAP.md) can be exercised end to
end in the provider sandbox.

