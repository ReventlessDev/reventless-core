open JestGlobals

// The domain id's two halves, shared by both platforms: a shape a reader can
// tell from a provider's `sub`, and one claim name a client reads whichever
// platform signed its token.

describe("Auth_UserId", () => {
  testSync("a minted id is not shaped like a UUID", () => {
    let id = Auth_UserId.mint()
    expect(id->String.startsWith("u_"))->toBe(true)
    expect(id->String.includes("-"))->toBe(false)
    expect(Auth_UserId.isMinted(id))->toBe(true)
  })

  testSync("two mints differ", () => expect(Auth_UserId.mint() == Auth_UserId.mint())->toBe(false))

  // The fallback every older account relies on: a Cognito `sub` must never read
  // as minted, or a reader would treat a provider id as the domain's own.
  testSync("a sub is not minted", () =>
    expect(Auth_UserId.isMinted("c3741234-aaaa-bbbb-cccc-ddddeeee1234"))->toBe(false)
  )

  testSync("the claim name is stable", () => expect(Auth_UserId.claim)->toBe("domainUserId"))
})
