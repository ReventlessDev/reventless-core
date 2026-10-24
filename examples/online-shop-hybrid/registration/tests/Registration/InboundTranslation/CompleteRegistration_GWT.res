@@reventless.gwt

open Registration_Examples

module Outcome = ReventlessGwt.Outcome

// The door a registration ends at. The password goes into the stash under the
// proof's hash, and only the hash travels on: nothing that would answer the
// challenge, and nothing that would sign in, reaches the command.

let password = goodPassword

let thenSubmits = async (pending, expected) =>
  switch (await pending).outcome {
  | Translated([(id, SubmitRegistrationProof({email, proofHash, _}))]) =>
    let actual = `${id}|${email->ContactAddressId.toString}|${proofHash}`
    actual == expected
      ? Outcome.pass
      : Outcome.fail(TranslateError({expected, actual: Some(actual)}))
  | _ => Outcome.fail(TranslateError({expected, actual: None}))
  }

describe("CompleteRegistration InboundTranslationSlice", () => {
  // scenario-id: 06245209-d526-44a9-8b8e-aac5ab65355b
  test("the proof travels as its hash", () =>
    whenInput({email: "Alice@Example.com", proof: "the-secret", password})->thenSubmits(
      `${aliceAddress}|${aliceAddress}|hash:the-secret`,
    )
  )

  // 🚨 The password is held for the slice that may act on it, under the key that
  // slice will be handed, and for minutes rather than for ever.
  // scenario-id: a79e5f26-5f82-4094-aa7c-0b9d74a1b6cd
  test("the password is stashed under the proof's hash", () =>
    whenInput({email: aliceAddress, proof: "the-secret", password})->thenSent([
      Hashed({input: "the-secret"}),
      Stashed({key: "hash:the-secret", value: password, ttl: passwordTtl}),
    ])
  )

  // Checked here, before the proof is spent, so a pool's policy cannot refuse the
  // account after the challenge has settled.
  // scenario-id: 9634063c-c36d-4cef-83c3-aaa27a86d5dc
  test("a short password is not understood, and nothing is held", () =>
    whenInput({email: "alice@example.com", proof: "the-secret", password: "short"})->thenNothingSent
  )

  // scenario-id: be4234e6-996b-4d3d-a365-dd42635d6d1e
  test("with no stash, the proof is not relayed", () =>
    whenInput(
      {email: "alice@example.com", proof: "the-secret", password},
      ~fakes=fakes(~stash=Reventless.Stash.unavailable(~reason="none here"), ()),
    )->thenNotUnderstood("cannot hold the password: none here")
  )
})
