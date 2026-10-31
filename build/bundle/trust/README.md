# Sigstore trust updates

Only the initial TUF root is embedded in the executable. `root.json` is version 16,
from [the official root-signing repository](https://github.com/sigstore/root-signing/blob/742eb2ab924b1967adeaca0c8d59358615b56a6f/metadata/root.json)
at commit `742eb2ab924b1967adeaca0c8d59358615b56a6f` (Apache-2.0).
Its SHA-256 is `27aea7e372aa7864065174f0661784fcf8b0e28b1dbfebeada31a0f1fb19167f`.
It is the bootstrap authority for updates, not a frozen copy of Fulcio/Rekor/CT
verification material. Replacing the bootstrap remains an explicit code review.

`../trust.zig` refreshes verification material from
`https://tuf-repo-cdn.sigstore.dev` using curl with HTTPS-only redirects, bounded
responses and timeouts. `../tuf.zig` authenticates the update natively:

- Sequential root rotation, with distinct-key signature thresholds from both
  the old and the new root. Authenticated roots are persisted immediately.
- Timestamp, snapshot and top-level targets role signatures over TUF's OLPC
  canonical JSON, plus metadata expiry and rollback checks.
- Parent/child metadata versions, optional metadata lengths/hashes and snapshot
  entry rollback/removal checks. Timestamp/snapshot trust is reset on role-key
  changes as required for root rotation.
- The exact length and hashes of the top-level `trusted_root.json` target.
- Consistent-snapshot metadata names and hash-prefixed target names.

The supported TUF profile is version 1.0 (including patch versions), ECDSA
P-256/SHA-256 role signatures, SHA-256/SHA-512 hashes, and at most 128 root
rotations from the embedded bootstrap. Only the top-level trust target is
resolved; delegated targets and unsupported algorithms fail closed.

The authenticated chain, metadata and target are stored together in `state.json`.
A process-wide cache file lock serializes reads/updates, and each write uses a
private temporary file, file sync and atomic rename. The cache defaults to
`$XDG_CACHE_HOME/pizza/sigstore` or `$HOME/.cache/pizza/sigstore` and can be changed
with `PIZZA_SIGSTORE_CACHE` or `verify-bundle --trust-cache PATH`.
The cache directory must be controlled by the user running the verifier.

Online verification always attempts a refresh and reports update failures;
there is no fallback to the former embedded verification snapshot.
`verify-bundle --offline` or `PIZZA_SIGSTORE_OFFLINE=1` uses the authenticated
cache without networking. It revalidates the chain, signatures, versions, target
hashes and expiry at the current time. An offline deployment must receive a
complete cache from a successful online update before its metadata expires.

`../sigstore.zig` receives the trusted verification material explicitly and
remains an offline verifier. Certificates or keys supplied with an artifact
never become roots. Its accepted release profile is Sigstore v0.3 DSSE,
ECDSA P-256/SHA-256 signing keys, the public Fulcio issuer chain, Rekor v1 DSSE
entries with SET and inclusion proof/checkpoint, and RFC 6962 SCT. Both official
spellings of the v0.3 bundle media type are accepted.

Standard-library DER Decoder/Encoder adapters and X.509 parsing/verification
live in `core/utils/`; Fulcio claims and code-signing usage policy remain in
`../fulcio.zig`. Signed publication times are checked against certificate and
verification-key validity, while TUF freshness uses the current update time.
The verifier does not audit upstream ELF contents.

The former verification-material snapshot is retained only as an offline test
fixture at `test/fixtures/sigstore/trusted_root.json`. Signed TUF fixtures in
`test/fixtures/sigstore/tuf/` were fetched from the official repository: roots
10–16, timestamp 813, snapshot 166 and targets 14. Tests use a fixed time so
fixture expiration does not introduce network or wall-clock dependencies.
