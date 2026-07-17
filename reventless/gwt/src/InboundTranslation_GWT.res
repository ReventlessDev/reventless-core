open ReventlessCore

// Minimal inline spec for InboundTranslationSlice. sury-ppx processes the
// @schema attributes in the same compilation unit as the functor — matches
// the pattern used by the other GWT DSLs.
module type SliceSpec = {
  let name: string

  @schema
  type externalInput

  @schema
  type command

  let translate: externalInput => result<array<(string, command)>, string>
}

module type T = {
  module Spec: SliceSpec

  let describe: (string, unit => unit) => unit
  let test: (string, unit => Outcome.outcome) => unit

  type translateResult = result<array<(string, Spec.command)>, string>

  let whenInput: Spec.externalInput => translateResult
  let thenCommands: (translateResult, array<(string, Spec.command)>) => Outcome.outcome
  let thenCommand: (translateResult, string, Spec.command) => Outcome.outcome
  let thenNoCommand: translateResult => Outcome.outcome
  let thenTranslateError: (translateResult, string) => Outcome.outcome
}

module Make = (Spec: SliceSpec): (T with module Spec = Spec) => {
  module Spec = Spec

  S.enableJson()

  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  type translateResult = result<array<(string, Spec.command)>, string>

  let encCommand = (c: Spec.command) => c->Message.encode(Spec.commandSchema)
  let encPairs = (pairs: array<(string, Spec.command)>) =>
    pairs->Array.map(((id, cmd)) => {
      let d = Dict.make()
      d->Dict.set("id", JSON.Encode.string(id))
      d->Dict.set("command", encCommand(cmd))
      JSON.Encode.object(d)
    })

  let whenInput = input => Spec.translate(input)

  let thenCommands = (result, expected) =>
    switch result {
    | Ok(actual) if actual == expected => Outcome.pass
    | Ok(actual) =>
      Outcome.fail(
        EventsMismatch({expected: encPairs(expected), actual: encPairs(actual)}),
      )
    | Error(msg) =>
      Outcome.fail(TranslateError({expected: "(commands)", actual: Some(msg)}))
    }

  let thenCommand = (result, expectedId, expectedCmd) =>
    thenCommands(result, [(expectedId, expectedCmd)])

  let thenNoCommand = result =>
    switch result {
    | Ok([]) => Outcome.pass
    | Ok(actual) => Outcome.fail(NoEventExpected({actual: encPairs(actual)}))
    | Error(msg) =>
      Outcome.fail(TranslateError({expected: "(no commands)", actual: Some(msg)}))
    }

  let thenTranslateError = (result, expectedMsg) =>
    switch result {
    | Error(actual) if actual == expectedMsg => Outcome.pass
    | Error(actual) =>
      Outcome.fail(TranslateError({expected: expectedMsg, actual: Some(actual)}))
    | Ok(_) => Outcome.fail(TranslateError({expected: expectedMsg, actual: None}))
    }
}
