open JestGlobals

// The sign-in attribute is the one pool setting no later deploy can correct, so
// what these cover is the parse: absent must mean today's behaviour, and a
// spelling this build does not know must refuse rather than default.

module LoginIdentifier = Auth_LoginIdentifier

describe("Auth_LoginIdentifier.parse", () => {
  testSync("absent is email, so an existing stack redeploys unchanged", () =>
    expect(LoginIdentifier.parse(None))->toEqual(Ok(LoginIdentifier.Email))
  )

  testSync("every spelling round-trips through its config name", () =>
    expect(
      LoginIdentifier.all->Array.map(i => LoginIdentifier.parse(Some(LoginIdentifier.toString(i)))),
    )->toEqual(LoginIdentifier.all->Array.map(i => Ok(i)))
  )

  // 🚨 A typo that defaulted would create a pool signing in on the wrong
  // attribute, and correcting that means replacing the pool and re-registering
  // every account in it.
  testSync("an unrecognised spelling refuses", () =>
    expect(LoginIdentifier.parse(Some("e-mail"))->Result.isError)->toBe(true)
  )

  testSync("the refusal names what was accepted instead", () =>
    expect(
      switch LoginIdentifier.parse(Some("e-mail")) {
      | Error(message) => message->String.includes("emailOrPhone")
      | Ok(_) => false
      },
    )->toBe(true)
  )

  // Case matters: Cognito's own attribute names are lowercase, and accepting
  // "Email" here would leave two spellings meaning one pool.
  testSync("a differently-cased spelling is not silently accepted", () =>
    expect(LoginIdentifier.parse(Some("Email"))->Result.isError)->toBe(true)
  )
})

describe("Auth_LoginIdentifier.usernameAttributes", () => {
  testSync("maps onto the attribute names Cognito takes at creation", () =>
    expect(LoginIdentifier.all->Array.map(LoginIdentifier.usernameAttributes))->toEqual([
      ["email"],
      ["phone_number"],
      ["email", "phone_number"],
    ])
  )
})
