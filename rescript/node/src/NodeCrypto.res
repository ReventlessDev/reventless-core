/** Bindings for [`node:crypto`](https://nodejs.org/api/crypto.html). */

/** A Node `Buffer`. Abstract rather than aliased to `Uint8Array.t`: a digest
    buffer is only ever fed back into `createHmac` or stringified, and giving it
    its own type keeps those two uses from being confused with file bytes. */
type buffer
@send external bufferToString: (buffer, string) => string = "toString"

// ── Hashing ──────────────────────────────────────────────────────────────────

type hash

@module("node:crypto")
external createHash: string => hash = "createHash"

@send external hashUpdate: (hash, string) => hash = "update"
@send external hashUpdateBuffer: (hash, Uint8Array.t) => hash = "update"
@send external hashDigest: (hash, string) => string = "digest"

/** SHA-256 of a UTF-8 string, hex-encoded. The content hash content-addressed
    stores key their objects on (`sha256/<hash>`): the same bytes always yield the
    same digest, so an upload is idempotent and deduplicating. */
let sha256Hex = (input: string): string =>
  createHash("sha256")->hashUpdate(input)->hashDigest("hex")

// ── HMAC ─────────────────────────────────────────────────────────────────────

type hmac

@module("node:crypto")
external createHmac: (string, string) => hmac = "createHmac"

/** The chained form: each round of an AWS SigV4 signing key takes the previous
    round's raw digest as its key. */
@module("node:crypto")
external createHmacFromBuffer: (string, buffer) => hmac = "createHmac"

@send external hmacUpdate: (hmac, string) => hmac = "update"
@send external hmacDigest: (hmac, string) => string = "digest"
@send external hmacDigestBuffer: hmac => buffer = "digest"

// ── Random ───────────────────────────────────────────────────────────────────

@module("node:crypto")
external randomBytes: int => buffer = "randomBytes"

@module("node:crypto")
external randomUUID: unit => string = "randomUUID"
