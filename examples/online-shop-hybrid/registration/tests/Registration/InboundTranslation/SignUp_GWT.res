@@reventless.gwt

// The door as the shop composes it: over the shop's admission table.
module SignUp_Translation = SignUp_Translation.Make(Admission)

open Registration_Examples

module Outcome = ReventlessGwt.Outcome

// The door a registration starts at. The time on the command is the moment the
// request arrived, read here at the edge, so it is not compared whole.

let thenRegisters = async (pending, expected) =>
  switch (await pending).outcome {
  | Translated([(id, Register({emailId, role, _}))]) =>
    let actual = `${id}|${emailId->ContactAddressId.toString}|${(role :> string)}`
    actual == expected
      ? Outcome.pass
      : Outcome.fail(TranslateError({expected, actual: Some(actual)}))
  | _ => Outcome.fail(TranslateError({expected, actual: None}))
  }

describe("SignUp InboundTranslationSlice", () => {
  // One address, however it was typed: the claim is on the address, so two
  // spellings of it must not be two claims.
  // scenario-id: 469fba42-1c66-4548-8014-a5258953e14b
  test("an address registers for the role it names, as one spelling", () =>
    whenInput({email: "  Alice@Example.com ", role: shopperName})->thenRegisters(
      `${aliceId}|${aliceId}|${shopperName}`,
    )
  )

  // The shop has one self-service role, so a sign-up need not say which.
  // scenario-id: 5a9c3e7b-2d4f-4b6a-8c1e-7f0d2a4b6c8e
  test("a sign-up naming no role asks for the one self-service role", () =>
    whenInput({email: aliceAddress})->thenRegisters(`${aliceId}|${aliceId}|${shopperName}`)
  )

  // The door relays whatever role it is asked for; the ledger is what answers a
  // role no visitor may have, and it answers it as it answers a closed one.
  // scenario-id: 9e1b7d3f-6a2c-4e8b-b0d4-3c5a7e9f1b2d
  test("a role no visitor may have is relayed, not refused at the door", () =>
    whenInput({email: aliceAddress, role: merchandiserName})->thenRegisters(
      `${aliceId}|${aliceId}|${merchandiserName}`,
    )
  )

  // The visitor has no account to say what they read, so the request says it, and the
  // ledger carries it to the mail. A value that is no language tag picks no words.
  let thenLanguage = async (pending, expected) =>
    switch (await pending).outcome {
    | Translated([(_, Register({?language}))]) if language == expected => Outcome.pass
    | Translated([(_, Register({?language}))]) =>
      Outcome.fail(
        TranslateError({
          expected: expected->Option.getOr("(none)"),
          actual: Some(language->Option.getOr("(none)")),
        }),
      )
    | _ => Outcome.fail(TranslateError({expected: "a Register", actual: None}))
    }

  test("the language the visitor reads in travels with the registration", () =>
    whenInput({email: aliceAddress, language: " de-AT "})->thenLanguage(Some("de-AT"))
  )

  test("a language that is not a tag is dropped, and the registration goes on", () =>
    whenInput({email: aliceAddress, language: "<script>"})->thenLanguage(None)
  )

  // scenario-id: 2547a470-7044-45b6-b7a0-530595f08567
  test("something that is not an address is not understood", () =>
    whenInput({email: "alice"})->thenNotUnderstood("not an email address")
  )

  // scenario-id: 608df706-9341-480c-9b8f-d86d0520a868
  test("starting a registration reaches no capability", () =>
    whenInput({email: aliceAddress})->thenNothingSent
  )
})
