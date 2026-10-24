@@reventless.gwt

open Registration_Examples

module Outcome = ReventlessGwt.Outcome

// The door a registration starts at. The time on the command is the moment the
// request arrived, read here at the edge, so it is not compared whole.

let thenRegisters = async (pending, expected) =>
  switch (await pending).outcome {
  | Translated([(id, Register({email, scopeId, _}))]) =>
    let actual = `${id}|${email->ContactAddressId.toString}|${scopeId}`
    actual == expected
      ? Outcome.pass
      : Outcome.fail(TranslateError({expected, actual: Some(actual)}))
  | _ => Outcome.fail(TranslateError({expected, actual: None}))
  }

describe("SignUp InboundTranslationSlice", () => {
  // One address, however it was typed: the claim is on the address, so two
  // spellings of it must not be two claims.
  // scenario-id: 469fba42-1c66-4548-8014-a5258953e14b
  test("an address registers under the default scope, as one spelling", () =>
    whenInput({email: "  Alice@Example.com "})->thenRegisters(
      `${aliceAddress}|${aliceAddress}|${defaultScope}`,
    )
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
