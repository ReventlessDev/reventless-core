@@reventless.gwt

open Registration_Examples

module Outcome = ReventlessGwt.Outcome

// What arrives at the address. A fresh registration gets the secret; a taken
// address gets a notice and nothing else — the difference the caller who
// started it never sees.

let fresh: outboundItem = {email: aliceId, address: aliceMail, alreadyRegistered: false}
let taken: outboundItem = {email: aliceId, address: aliceMail, alreadyRegistered: true}
let invitation: outboundItem = {
  email: aliceId,
  address: aliceMail,
  alreadyRegistered: false,
  invited: true,
  roles: [merchandiserName],
}
/** A reissued invitation's code: worded as an invitation, but the event does
    not say as what. */
let reissuedInvitation: outboundItem = {
  email: aliceId,
  address: aliceMail,
  alreadyRegistered: false,
  invited: true,
}

let policy = ContactVerification.emailPolicy

let withSecrets = () =>
  fakes(~token="known-secret", ~hash=t => `hashed:${t}`, ~channels=[Email], ())

let thenLedgerTold = async (pending, expected) =>
  switch (await pending).result {
  | Ok(Some((_, IssueRegistrationChallenge({email, proofHash, _})))) =>
    let actual = `${email->ContactAddressId.toString}|${proofHash}`
    actual == expected
      ? Outcome.pass
      : Outcome.fail(TranslateError({expected, actual: Some(actual)}))
  | _ => Outcome.fail(TranslateError({expected, actual: None}))
  }

let mail = (~subject, ~body): ReventlessGwt.Capabilities_Fake.call => Sent({
  recipient: ToEmail(Reventless.Email.unsafe(aliceAddress)),
  message: {subject, body},
})

describe("SendRegistrationChallenge OutboundTranslationSlice", () => {
  // scenario-id: 4095f5ec-db7f-40f7-a851-a268a5a779df
  testSync("a request is collected once per address and time", () =>
    givenEvent(
      RegistrationRequested({
        email: aliceId,
        address: Reventless.Pii.Value(aliceMail),
        requestedAt: "2026-10-24T09:00:00.000Z",
      }),
    )
    ->whenCollect
    ->thenTodos([("fp:contactAddress:alice@example.com:2026-10-24T09:00:00.000Z", fresh)])
  )

  testSync("an erased address is not written to", () =>
    givenEvent(
      RegistrationRequested({
        email: aliceId,
        address: Reventless.Pii.Erased,
        requestedAt: "2026-10-24T09:00:00.000Z",
      }),
    )
    ->whenCollect
    ->thenTodos([])
  )

  // scenario-id: 6102d230-f0c8-46c1-967f-d82fb1f97226
  testSync("an invitation is collected as one, apart from a sign-up at the same time", () =>
    givenEvent(
      RegistrationInvited({
        email: aliceId,
        address: Reventless.Pii.Value(aliceMail),
        roles: [merchandiserName],
        invitedBy: "u_inviter",
        invitedAt: "2026-10-24T09:00:00.000Z",
      }),
    )
    ->whenCollect
    ->thenTodos([
      ("fp:contactAddress:alice@example.com:invited:2026-10-24T09:00:00.000Z", invitation),
    ])
  )

  // A reissued code is worded as its claim was.
  // scenario-id: 5dd47462-a2f8-4594-a9da-4b668a42a662
  testSync("a reissued invitation's code is collected as an invitation", () =>
    givenEvent(
      RegistrationChallengeReissued({
        email: aliceId,
        address: Reventless.Pii.Value(aliceMail),
        reissuedAt: "2026-10-25T09:00:00.000Z",
        invitedBy: "u_inviter",
      }),
    )
    ->whenCollect
    ->thenTodos([
      ("fp:contactAddress:alice@example.com:reissued:2026-10-25T09:00:00.000Z", reissuedInvitation),
    ])
  )

  // scenario-id: 90b3573e-65c5-48c5-935a-3bcfa702d8b5
  testSync("a reissued sign-up's code is collected as a sign-up", () =>
    givenEvent(
      RegistrationChallengeReissued({
        email: aliceId,
        address: Reventless.Pii.Value(aliceMail),
        reissuedAt: "2026-10-25T09:00:00.000Z",
      }),
    )
    ->whenCollect
    ->thenTodos([
      (
        "fp:contactAddress:alice@example.com:reissued:2026-10-25T09:00:00.000Z",
        {email: aliceId, address: aliceMail, alreadyRegistered: false, invited: false},
      ),
    ])
  )

  // scenario-id: 102e1331-79c0-4fa9-973c-4d07609b34df
  test("a challenge is opened against the hash, never the secret", () =>
    givenTodo("t1", fresh)
    ->givenCapabilities(withSecrets())
    ->whenTranslated
    ->thenLedgerTold("fp:contactAddress:alice@example.com|hashed:known-secret")
  )

  // scenario-id: 4e43e47e-e5b1-4c5a-9619-a83ec78a9fb8
  test("the secret itself is what goes to the address", () =>
    givenTodo("t1", fresh)
    ->givenCapabilities(withSecrets())
    ->whenTranslated
    ->thenSent([
      TokenDrawn({length: policy.proofLength, alphabet: policy.proofAlphabet}),
      Hashed({input: "known-secret"}),
      mail(~subject="Finish your registration", ~body=challengeBody(~token="known-secret")),
    ])
  )

  // The invitation holds a week, which its wording says, and it names what it
  // grants.
  // scenario-id: 913f90ca-b8a9-4716-a03f-e2e86a073be3
  test("an invitation's secret goes out worded as an invitation, naming the roles", () =>
    givenTodo("t3", invitation)
    ->givenCapabilities(withSecrets())
    ->whenTranslated
    ->thenSent([
      TokenDrawn({length: policy.proofLength, alphabet: policy.proofAlphabet}),
      Hashed({input: "known-secret"}),
      mail(
        ~subject="You are invited to create an account",
        ~body=invitationBody(~token="known-secret", ~roles=[merchandiserName]),
      ),
    ])
  )

  // scenario-id: 6b1d2f8a-4c3e-4a9b-8d7f-2e5c1a9b3d40
  test("a reissued invitation's secret is worded as an invitation, with no role to name", () =>
    givenTodo("t4", reissuedInvitation)
    ->givenCapabilities(withSecrets())
    ->whenTranslated
    ->thenSent([
      TokenDrawn({length: policy.proofLength, alphabet: policy.proofAlphabet}),
      Hashed({input: "known-secret"}),
      mail(
        ~subject="You are invited to create an account",
        ~body=invitationBody(~token="known-secret"),
      ),
    ])
  )

  // scenario-id: 18ffc082-763e-415b-a1b3-61d5c788cb19
  test("a taken address is told someone tried, and no challenge opens", () =>
    givenTodo("t2", taken)
    ->givenCapabilities(withSecrets())
    ->whenTranslated
    ->thenSent([mail(~subject="Someone tried to register with your address", ~body=noticeBody)])
  )

  // scenario-id: 72e8341c-1289-48bd-b8f0-c09202bccba5
  test("a notice sends nothing back to the ledger", () =>
    givenTodo("t2", taken)->givenCapabilities(withSecrets())->whenTranslated->thenNoCommand
  )
})
