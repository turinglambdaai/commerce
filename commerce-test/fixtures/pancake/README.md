# Pancake webhook protocol fixtures

These fixtures exercise the public Waffo Pancake webhook wire contract without
containing a provider secret or a real customer event. They were captured on
2026-10-16 with Node.js `crypto` using disposable RSA-2048 key pairs and the
released Waffo Pancake v0.17.0 signing representation:

```text
timestamp-milliseconds + "." + exact raw JSON bytes
```

The payload files deliberately end in one LF byte. The signatures therefore
prove that Commerce verifies exact bytes instead of parsed/re-serialized JSON.
Repository attributes preserve LF for every fixture on all three desktop
platforms; changing checkout policy must not rewrite this evidence.
Only public keys are retained. `invalid-signature.txt` changes one signed byte;
`mode-mismatch.json` is validly signed by the test key while claiming `prod`,
so environment binding can be tested independently from cryptographic validity.
The duplicate-field fixture uses a second disposable key to prove an
authenticated but ambiguous envelope is rejected.

The valid fixture was independently accepted by the official Go SDK v0.17.0
`VerifyWebhook` implementation using its custom-public-key path.

These are protocol-conformance fixtures, not evidence of a live Pancake sandbox
delivery. Sandbox evidence remains a later M1 gate.
