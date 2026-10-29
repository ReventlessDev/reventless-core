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

// ── AES-256-GCM ──────────────────────────────────────────────────────────────

type cipher
type decipher

@module("node:crypto")
external createCipheriv: (string, buffer, buffer) => cipher = "createCipheriv"
@module("node:crypto")
external createDecipheriv: (string, buffer, buffer) => decipher = "createDecipheriv"

@send external cipherUpdate: (cipher, buffer) => buffer = "update"
@send external cipherFinal: cipher => buffer = "final"
@send external cipherGetAuthTag: cipher => buffer = "getAuthTag"
@send external cipherSetAad: (cipher, buffer) => cipher = "setAAD"
@send external decipherUpdate: (decipher, buffer) => buffer = "update"
@send external decipherFinal: decipher => buffer = "final"
@send external decipherSetAuthTag: (decipher, buffer) => decipher = "setAuthTag"
@send external decipherSetAad: (decipher, buffer) => decipher = "setAAD"

@module("node:buffer") @scope("Buffer")
external bufferFromString: (string, string) => buffer = "from"
@module("node:buffer") @scope("Buffer")
external bufferConcat: array<buffer> => buffer = "concat"
@get external bufferLength: buffer => int = "length"
@send external bufferSubarray: (buffer, int, int) => buffer = "subarray"

/** The algorithm's name as `node:crypto` spells it. */
let aes256gcm = "aes-256-gcm"

/** A GCM nonce is 12 bytes; its tag 16. */
let gcmNonceBytes = 12
let gcmTagBytes = 16

/** A fresh 32-byte key, for a test or for a provider that mints its own. */
let aesKey = (): buffer => randomBytes(32)

/**
Encrypt UTF-8 `plaintext` under a 32-byte `key` with a random nonce: the result is
`nonce ‖ ciphertext ‖ tag`, base64. `aad`, when given, is authenticated and not
encrypted: a value sealed for one field and subject cannot be moved to another
when both are bound as `aad`.
*/
let aesGcmEncrypt = (~key: buffer, ~aad: option<string>=?, plaintext: string): string => {
  let nonce = randomBytes(gcmNonceBytes)
  let cipher = createCipheriv(aes256gcm, key, nonce)
  aad->Option.forEach(a => {
    let _ = cipher->cipherSetAad(bufferFromString(a, "utf8"))
  })
  let body = bufferConcat([
    cipher->cipherUpdate(bufferFromString(plaintext, "utf8")),
    cipher->cipherFinal,
  ])
  bufferConcat([nonce, body, cipher->cipherGetAuthTag])->bufferToString("base64")
}

/** The inverse of `aesGcmEncrypt`: `Error` when the bytes, the tag, the key or the
    `aad` do not match, never a wrong plaintext. */
let aesGcmDecrypt = (~key: buffer, ~aad: option<string>=?, sealed: string): result<
  string,
  string,
> =>
  try {
    let all = bufferFromString(sealed, "base64")
    let len = all->bufferLength
    if len < gcmNonceBytes + gcmTagBytes {
      Error("too short to be a sealed value")
    } else {
      let nonce = all->bufferSubarray(0, gcmNonceBytes)
      let tag = all->bufferSubarray(len - gcmTagBytes, len)
      let body = all->bufferSubarray(gcmNonceBytes, len - gcmTagBytes)
      let decipher = createDecipheriv(aes256gcm, key, nonce)->decipherSetAuthTag(tag)
      aad->Option.forEach(a => {
        let _ = decipher->decipherSetAad(bufferFromString(a, "utf8"))
      })
      Ok(
        bufferConcat([decipher->decipherUpdate(body), decipher->decipherFinal])->bufferToString(
          "utf8",
        ),
      )
    }
  } catch {
  | _ => Error("the value does not open under this key")
  }
