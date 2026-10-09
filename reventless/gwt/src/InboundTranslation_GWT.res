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

/** Deprecated: takes an adapter module with `translate` on the spec. Use
    `FromSlice`; this goes one release after the examples have moved. */
module Make = (Spec: SliceSpec): (T with module Spec = Spec) => {
  module Spec = Spec

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
      Outcome.fail(EventsMismatch({expected: encPairs(expected), actual: encPairs(actual)}))
    | Error(msg) => Outcome.fail(TranslateError({expected: "(commands)", actual: Some(msg)}))
    }

  let thenCommand = (result, expectedId, expectedCmd) =>
    thenCommands(result, [(expectedId, expectedCmd)])

  let thenNoCommand = result =>
    switch result {
    | Ok([]) => Outcome.pass
    | Ok(actual) => Outcome.fail(NoEventExpected({actual: encPairs(actual)}))
    | Error(msg) => Outcome.fail(TranslateError({expected: "(no commands)", actual: Some(msg)}))
    }

  let thenTranslateError = (result, expectedMsg) =>
    switch result {
    | Error(actual) if actual == expectedMsg => Outcome.pass
    | Error(actual) => Outcome.fail(TranslateError({expected: expectedMsg, actual: Some(actual)}))
    | Ok(_) => Outcome.fail(TranslateError({expected: expectedMsg, actual: None}))
    }
}

// The slice as written: its `Spec` and its `_Translation` body.
module FromSlice = (
  Spec: Reventless.InboundTranslationSlice.Spec,
  Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
) => {
  let describe = JestBind.describe
  let test = (name, body) => JestBind.test(~slice=Spec.name, name, body)

  /** What became of one input. `InputRefused` is input that did not decode, so
      `translate` never saw it; `NotUnderstood` is input it declined. */
  type received =
    | Translated(array<(string, Spec.command)>)
    | NotUnderstood(string)
    | InputRefused(string)

  let encPairs = (pairs: array<(string, Spec.command)>) =>
    pairs->Array.map(((id, cmd)) => {
      let d = Dict.make()
      d->Dict.set("id", JSON.Encode.string(id))
      d->Dict.set("command", cmd->Message.encode(Spec.commandSchema))
      JSON.Encode.object(d)
    })

  let whenInput = (input: Spec.externalInput) =>
    switch Translation.translate(input) {
    | Ok(pairs) => Translated(pairs)
    | Error(msg) => NotUnderstood(msg)
    }

  /** Input as it arrives: decoded through `externalInputSchema` first. */
  let whenReceived = (json: JSON.t) =>
    switch json->Reventless.Util_Sury.fromJson(Spec.externalInputSchema) {
    | input => whenInput(input)
    // Sury's message names the field that failed.
    | exception S.Exn(e) => InputRefused(e.message)
    | exception _ => InputRefused("invalid input")
    }

  let describeOther = received =>
    switch received {
    | Translated(_) => None
    | NotUnderstood(msg) => Some(`not understood: ${msg}`)
    | InputRefused(msg) => Some(`input refused: ${msg}`)
    }

  // Each command must survive its own schema both ways, as it will on the topic.
  let roundTrips = (cmd: Spec.command) =>
    switch cmd
    ->Message.encode(Spec.commandSchema)
    ->Reventless.Util_Sury.fromJson(Spec.commandSchema) {
    | back => back == cmd
    | exception _ => false
    }

  let thenCommands = (received, expected) =>
    switch received {
    | Translated(actual) if actual == expected =>
      switch actual->Array.find(((_, cmd)) => !roundTrips(cmd)) {
      | None => Outcome.pass
      | Some(pair) =>
        Outcome.fail(
          TranslateError({
            expected: "commands that encode and decode through commandSchema",
            actual: Some(`${JSON.stringifyAny(encPairs([pair]))->Option.getOr("")} does not`),
          }),
        )
      }
    | Translated(actual) =>
      Outcome.fail(EventsMismatch({expected: encPairs(expected), actual: encPairs(actual)}))
    | other => Outcome.fail(TranslateError({expected: "(commands)", actual: describeOther(other)}))
    }

  let thenCommand = (received, expectedId, expectedCmd) =>
    thenCommands(received, [(expectedId, expectedCmd)])

  let thenNoCommand = received =>
    switch received {
    | Translated([]) => Outcome.pass
    | Translated(actual) => Outcome.fail(NoEventExpected({actual: encPairs(actual)}))
    | other =>
      Outcome.fail(TranslateError({expected: "(no commands)", actual: describeOther(other)}))
    }

  let thenNotUnderstood = (received, expectedMsg) =>
    switch received {
    | NotUnderstood(actual) if actual == expectedMsg => Outcome.pass
    | NotUnderstood(actual) =>
      Outcome.fail(TranslateError({expected: expectedMsg, actual: Some(actual)}))
    | other => Outcome.fail(TranslateError({expected: expectedMsg, actual: describeOther(other)}))
    }
  let thenTranslateError = thenNotUnderstood

  /** Passes when the input was refused and the reason contains `reason`: the
      decoder words its own messages, so a test pins the part that matters. */
  let thenRefusedInput = (received, reason) =>
    switch received {
    | InputRefused(actual) if actual->String.includes(reason) => Outcome.pass
    | other =>
      Outcome.fail(
        TranslateError({
          expected: `input refused: …${reason}…`,
          actual: switch other {
          | Translated(_) => Some("translated")
          | other => describeOther(other)
          },
        }),
      )
    }
}
