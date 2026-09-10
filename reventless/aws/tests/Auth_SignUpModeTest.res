open JestGlobals

// Sign-up mode is correctable on a live pool, unlike the sign-in attribute, so
// what these cover is not permanence but silence: absent must mean today's
// behaviour, an unknown spelling must refuse rather than quietly close the pool,
// and the mapping onto Cognito's inverted field must not be readable backwards.

module SignUpMode = Auth_SignUpMode

describe("Auth_SignUpMode.parse", () => {
  testSync("absent is adminOnly, so an existing stack redeploys unchanged", () =>
    expect(SignUpMode.parse(None))->toEqual(Ok(SignUpMode.AdminOnly))
  )

  testSync("every spelling round-trips through its config name", () =>
    expect(SignUpMode.all->Array.map(m => SignUpMode.parse(Some(SignUpMode.toString(m)))))->toEqual(
      SignUpMode.all->Array.map(m => Ok(m)),
    )
  )

  // 🚨 Defaulting past a typo fails CLOSED, which is safe and invisible: the
  // deploy is green, the config reads as though registration is open, and the
  // only symptom is every registration being refused — far from the cause.
  testSync("an unrecognised spelling refuses", () =>
    expect(SignUpMode.parse(Some("self-service"))->Result.isError)->toBe(true)
  )

  testSync("the refusal names what was accepted instead", () =>
    expect(
      switch SignUpMode.parse(Some("self-service")) {
      | Error(message) => message->String.includes("selfService")
      | Ok(_) => false
      },
    )->toBe(true)
  )

  testSync("a differently-cased spelling is not silently accepted", () =>
    expect(SignUpMode.parse(Some("SelfService"))->Result.isError)->toBe(true)
  )
})

describe("Auth_SignUpMode.allowAdminCreateUserOnly", () => {
  // Cognito asks the opposite of what this type asks. Pinning both arms is the
  // point: an inverted mapping would open a pool meant to stay closed, and on a
  // shared pool it would open it for every stack using it.
  testSync("inverts the question Cognito's field asks", () =>
    expect((
      SignUpMode.AdminOnly->SignUpMode.allowAdminCreateUserOnly,
      SignUpMode.SelfService->SignUpMode.allowAdminCreateUserOnly,
    ))->toEqual((true, false))
  )

  testSync("the default leaves the pool admin-create-only", () =>
    expect(SignUpMode.default->SignUpMode.allowAdminCreateUserOnly)->toBe(true)
  )
})
