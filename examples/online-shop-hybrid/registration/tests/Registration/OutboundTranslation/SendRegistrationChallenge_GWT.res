@@reventless.gwt

open Registration_Examples

module Outcome = ReventlessGwt.Outcome

// What arrives at the address. A fresh registration gets the secret; a taken
// address gets a notice and nothing else — the difference the caller who
// started it never sees.

let fresh: outboundItem = {email: aliceAddress, alreadyRegistered: false}
let taken: outboundItem = {email: aliceAddress, alreadyRegistered: true}

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
      RegistrationRequested({email: aliceAddress, requestedAt: "2026-10-24T09:00:00.000Z"}),
    )
    ->whenCollect
    ->thenTodos([("alice@example.com:2026-10-24T09:00:00.000Z", fresh)])
  )

  // scenario-id: 102e1331-79c0-4fa9-973c-4d07609b34df
  test("a challenge is opened against the hash, never the secret", () =>
    givenTodo("t1", fresh)
    ->givenCapabilities(withSecrets())
    ->whenTranslated
    ->thenLedgerTold("alice@example.com|hashed:known-secret")
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
