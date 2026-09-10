open JestGlobals

// The secret source. What matters here is not that it produces characters, but
// that it produces them uniformly — a token drawn from a skewed distribution is
// guessable in a way that no other test would notice.

module Secrets = Reventless.Secrets
module Backend = Secrets_Node_Backend

let token = (~length, ~alphabet) =>
  Backend.provider.randomToken(~length, ~alphabet)->Result.getOr("")

describe("randomToken", () => {
  testSync("draws the requested length", () =>
    expect(
      [1, 6, 32, 64]->Array.map(length => token(~length, ~alphabet=Digits)->String.length),
    )->toEqual([1, 6, 32, 64])
  )

  testSync("draws only from the alphabet it was given", () => {
    let allowed = Secrets.characters(UrlSafe)
    expect(
      token(~length=512, ~alphabet=UrlSafe)
      ->String.split("")
      ->Array.every(c => allowed->String.includes(c)),
    )->toBe(true)
  })

  testSync("digits are digits", () =>
    expect(
      token(~length=512, ~alphabet=Digits)
      ->String.split("")
      ->Array.every(c => "0123456789"->String.includes(c)),
    )->toBe(true)
  )

  // Not proof of randomness — it is proof the source is not a constant, which is
  // the failure a fixed or broken binding would produce.
  testSync("two draws differ", () =>
    expect(token(~length=32, ~alphabet=UrlSafe) == token(~length=32, ~alphabet=UrlSafe))->toBe(
      false,
    )
  )

  // A zero-length token would compare equal to nothing and settle every
  // challenge presented against it, so it is refused rather than clamped.
  testSync("a non-positive length is refused, not clamped", () =>
    expect(
      [0, -1]->Array.map(
        length => Backend.provider.randomToken(~length, ~alphabet=Digits)->Result.isError,
      ),
    )->toEqual([true, true])
  )
})

// 🚨 Checked over every byte value rather than by sampling the output, and the
// first attempt here got that wrong. `byte % 10` skews the low six digits by
// about four percent each — roughly 0.609 of draws landing in the low half
// against 0.600 for a fair source. At any sample size a test can afford that
// gap is a couple of standard errors, so a sampled assertion either flakes or,
// as the first version did, passes happily with the defence deleted.
describe("accepts — the rejection rule", () => {
  let rejected = size =>
    Array.fromInitializer(~length=256, i => i)->Array.filter(byte => !Backend.accepts(~byte, ~size))

  testSync("rejects exactly the bytes that would skew a 10-character alphabet", () =>
    expect(rejected(10))->toEqual([250, 251, 252, 253, 254, 255])
  )

  // 64 divides 256 exactly, so nothing needs discarding and a url-safe token
  // costs no extra draws.
  testSync("rejects nothing when the alphabet divides evenly", () =>
    expect(rejected(64))->toEqual([])
  )

  // What survives always folds onto a whole number of cycles, which is the
  // property that makes every character equally likely.
  testSync("what it accepts is a whole multiple of the alphabet", () =>
    expect(
      [2, 3, 7, 10, 16, 26, 62, 64]->Array.map(
        size => mod(256 - rejected(size)->Array.length, size),
      ),
    )->toEqual([0, 0, 0, 0, 0, 0, 0, 0])
  )

  testSync("never discards more than one cycle's worth", () =>
    expect([3, 7, 10, 26, 62]->Array.map(size => rejected(size)->Array.length < size))->toEqual([
      true,
      true,
      true,
      true,
      true,
    ])
  )
})

describe("hash", () => {
  testSync("is deterministic, which is what lets a proof be compared", () =>
    expect(Backend.provider.hash("a-secret") == Backend.provider.hash("a-secret"))->toBe(true)
  )

  testSync("separates different inputs", () =>
    expect(Backend.provider.hash("a-secret") == Backend.provider.hash("a-secret "))->toBe(false)
  )

  // One-way: the digest must not carry the secret it was made from.
  testSync("does not contain its input", () =>
    expect(
      Backend.provider.hash("a-secret")
      ->Result.getOr("")
      ->String.includes("a-secret"),
    )->toBe(false)
  )
})

describe("Capabilities.none.secrets", () => {
  // Refusing rather than degrading: there is no weaker token that would be safe
  // to hand back, so an unwired platform must fail rather than produce one.
  testSync("refuses both operations", () =>
    expect((
      Reventless.Capabilities.none.secrets.randomToken(
        ~length=32,
        ~alphabet=UrlSafe,
      )->Result.isError,
      Reventless.Capabilities.none.secrets.hash("x")->Result.isError,
    ))->toEqual((true, true))
  )
})

describe("Secrets.fixed", () => {
  // What a consumer's suite uses to know the secret before presenting it.
  let provider = Secrets.fixed(~token="known", ~hash=input => `hashed:${input}`)

  testSync("hands back the token it was built with", () =>
    expect(provider.randomToken(~length=32, ~alphabet=UrlSafe))->toEqual(Ok("known"))
  )

  testSync("hashes through the function it was given", () =>
    expect(provider.hash("known"))->toEqual(Ok("hashed:known"))
  )
})
