// The AES-256-GCM binding an encrypting provider seals values with.

open JestGlobals

let key = NodeCrypto.aesKey()

describe("NodeCrypto AES-256-GCM", () => {
  testSync("round-trips, and never repeats a ciphertext", () => {
    let a = NodeCrypto.aesGcmEncrypt(~key, "Ada Lovelace")
    let b = NodeCrypto.aesGcmEncrypt(~key, "Ada Lovelace")
    expect(a == b)->toBe(false)
    expect(NodeCrypto.aesGcmDecrypt(~key, a))->toEqual(Ok("Ada Lovelace"))
    expect(a->String.includes("Ada"))->toBe(false)
  })

  testSync("a tampered value does not open", () => {
    let sealed = NodeCrypto.aesGcmEncrypt(~key, "Ada Lovelace")
    let flipped = sealed->String.charAt(20) == "A" ? "B" : "A"
    let tampered =
      sealed->String.slice(~start=0, ~end=20) ++ flipped ++ sealed->String.slice(~start=21)
    expect(NodeCrypto.aesGcmDecrypt(~key, tampered)->Result.isError)->toBe(true)
  })

  testSync("another key, or another aad, does not open it", () => {
    let sealed = NodeCrypto.aesGcmEncrypt(~key, ~aad="member-1/name", "Ada")
    expect(
      NodeCrypto.aesGcmDecrypt(
        ~key=NodeCrypto.aesKey(),
        ~aad="member-1/name",
        sealed,
      )->Result.isError,
    )->toBe(true)
    expect(NodeCrypto.aesGcmDecrypt(~key, ~aad="member-2/name", sealed)->Result.isError)->toBe(true)
    expect(NodeCrypto.aesGcmDecrypt(~key, ~aad="member-1/name", sealed))->toEqual(Ok("Ada"))
  })

  testSync("a value too short to hold a nonce and a tag is refused", () =>
    expect(NodeCrypto.aesGcmDecrypt(~key, "AAAA")->Result.isError)->toBe(true)
  )
})
