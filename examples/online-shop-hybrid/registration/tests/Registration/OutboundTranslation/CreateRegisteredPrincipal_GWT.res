@@reventless.gwt

open Registration_Examples

// Turning an accepted proof into an account. The password is taken from the
// stash the door put it in, once, and handed to the identity provider.

let item: outboundItem = {email: aliceAddress, roles: [shopper], proofHash: "h"}
let held = () => fakes(~stashed=[("h", goodPassword)], ())

let created: ReventlessGwt.Capabilities_Fake.call = PrincipalCreated({
  contact: ToEmail(Reventless.Email.unsafe(aliceAddress)),
  credential: Password(goodPassword),
  groups: [shopperName],
})

describe("CreateRegisteredPrincipal OutboundTranslationSlice", () => {
  // scenario-id: 7c6dbee1-2a04-4eac-be89-24679ab14423
  test("an accepted proof becomes an account with the password typed beside it", () =>
    givenTodo("t1", item)
    ->givenCapabilities(held())
    ->whenTranslated
    ->thenSent([Taken({key: "h"}), created])
  )

  // A registration granting several roles makes one account in all their groups.
  // scenario-id: 1c7e9a3b-5d2f-4b8a-9e6c-0f3a5b7d9e1c
  test("several roles land in all their groups", () =>
    givenTodo("t1", {...item, roles: [shopper, merchandiser]})
    ->givenCapabilities(held())
    ->whenTranslated
    ->thenSent([
      Taken({key: "h"}),
      PrincipalCreated({
        contact: ToEmail(Reventless.Email.unsafe(aliceAddress)),
        credential: Password(goodPassword),
        groups: [shopperName, merchandiserName],
      }),
    ])
  )

  // scenario-id: ef686ab8-6e38-467c-a77c-c4e951e41d83
  test("the ledger is told the registration completed", () =>
    givenTodo("t1", item)
    ->givenCapabilities(held())
    ->whenTranslated
    ->thenCommand(aliceAddress, RecordRegistrationCompleted({email: alice}))
  )

  // An address the provider already holds is as registered as one made here.
  // scenario-id: 7e33f9db-891d-4134-8ea2-c442a3a30f4b
  test("an existing account still completes the registration", () =>
    givenTodo("t1", item)
    ->givenCapabilities(
      fakes(
        ~stashed=[("h", goodPassword)],
        ~createPrincipal=async (~contact as _, ~credential as _, ~groups as _) => Error(Conflict),
        (),
      ),
    )
    ->whenTranslated
    ->thenCommand(aliceAddress, RecordRegistrationCompleted({email: alice}))
  )

  // scenario-id: 00c97b0d-231a-420e-8570-665945551631
  test("a password that has expired makes no account", () =>
    givenTodo("t1", item)
    ->givenCapabilities(fakes())
    ->whenTranslated
    ->thenSent([Taken({key: "h"})])
  )

  // The retry must find the password again, or it reports it gone.
  // scenario-id: 2bf8593b-fcfa-4e51-a02d-29af156f8e07
  test("a provider that is down gets the password back for the retry", () =>
    givenTodo("t1", item)
    ->givenCapabilities(
      fakes(
        ~stashed=[("h", goodPassword)],
        ~createPrincipal=async (~contact as _, ~credential as _, ~groups as _) => Error(
          Unavailable("down"),
        ),
        (),
      ),
    )
    ->whenTranslated
    ->thenSent([
      Taken({key: "h"}),
      created,
      Stashed({key: "h", value: goodPassword, ttl: retryTtl}),
    ])
  )
})
