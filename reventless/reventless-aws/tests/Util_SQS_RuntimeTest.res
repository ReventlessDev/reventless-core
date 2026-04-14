open TestHelpers

let shortId = "environment:alpha#platformName:online-shop#pluginName:Catalog"
let longId =
  "componentName:DcbEventLog#environment:alpha#platformName:online-shop-platform-aws#pluginName:Catalog#resourceName:CatalogDcbEventLog-428c0a8"

describe("Util_SQS_Runtime.safeGroupId", () => {
  test("returns id unchanged when ≤ 128 chars", () => {
    expect(shortId->String.length <= 128)->toBe(true)
    expect(Util_SQS_Runtime.safeGroupId(shortId))->toBe(shortId)
  })

  test("returns SHA-256 hex (64 chars) when id exceeds 128 chars", () => {
    expect(longId->String.length > 128)->toBe(true)
    let result = Util_SQS_Runtime.safeGroupId(longId)
    expect(result->String.length)->toBe(64)
    // SHA-256 hex uses only [0-9a-f]
    expect(result->String.includes(" "))->toBe(false)
  })

  test("returns different hashes for different long ids", () => {
    let longId2 =
      "componentName:Products#environment:alpha#platformName:online-shop-platform-aws#pluginName:Catalog#resourceName:ProductsTable-abc1234"
    expect(longId2->String.length > 128)->toBe(true)
    expect(
      Util_SQS_Runtime.safeGroupId(longId) == Util_SQS_Runtime.safeGroupId(longId2)
    )->toBe(false)
  })

  test("returns same hash for the same long id (deterministic)", () => {
    expect(Util_SQS_Runtime.safeGroupId(longId))->toBe(Util_SQS_Runtime.safeGroupId(longId))
  })

  test("boundary: 128-char id is returned unchanged", () => {
    let exactly128 = "a"->String.repeat(128)
    expect(exactly128->String.length)->toBe(128)
    expect(Util_SQS_Runtime.safeGroupId(exactly128))->toBe(exactly128)
  })

  test("boundary: 129-char id is hashed", () => {
    let exactly129 = "a"->String.repeat(129)
    expect(exactly129->String.length)->toBe(129)
    let result = Util_SQS_Runtime.safeGroupId(exactly129)
    expect(result->String.length)->toBe(64)
  })
})
