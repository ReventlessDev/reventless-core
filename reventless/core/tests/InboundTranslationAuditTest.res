open JestGlobals

// Which inbound slices keep an audit log of what they receive: not one whose door
// is open to visitors, by its commands' rules, as its door is decided.

@schema
type command =
  | Register({email: string})
  | Remind({email: string})

let keeps = (rule: string => Reventless.Authorization.permission) =>
  InboundTranslationSlice.keepsAudit(
    ~commandSchema=commandSchema->S.castToUnknown,
    ~authorizationOf=rule,
  )

describe("InboundTranslationSlice.keepsAudit", () => {
  testSync("a door open to visitors keeps no audit log", () =>
    expect(keeps(_ => AllowAnonymous))->toBe(false)
  )

  testSync("a door for signed-in callers keeps one", () =>
    expect(keeps(_ => AllowAuthenticated))->toBe(true)
  )

  testSync("a door whose commands ask for roles keeps one", () =>
    expect(keeps(_ => AllowRoles([Reventless.Role.admin])))->toBe(true)
  )
})
