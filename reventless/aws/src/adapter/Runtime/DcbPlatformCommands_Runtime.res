// Commands an automation or an outbound translation sends to its plugin's DCB command
// Lambda by invoking it, rather than through the queue, so it hears each one's outcome.
// The Lambda answers on Route P (`DcbCommandTopicEntryPoint.mjs`).

/** The invocation payload: the commands as `{id, meta, commandJson}`. */
let payloadOf = (cmdJsons: array<Reventless.Message.commandJson>): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      ("__platformCommands", JSON.Encode.bool(true)),
      (
        "commands",
        cmdJsons
        ->Array.map(cmdJson =>
          JSON.Encode.object(
            Dict.fromArray([
              ("id", JSON.Encode.string(cmdJson.id)),
              ("meta", cmdJson.meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema)),
              ("commandJson", cmdJson.commandJson),
            ]),
          )
        )
        ->JSON.Encode.array,
      ),
    ]),
  )

/** The outcomes the Lambda answered with, in the order sent. A command whose outcome
    cannot be read counts as not yet answered. */
let outcomesOf = (cmdJsons: array<Reventless.Message.commandJson>, answer: JSON.t): array<
  ReventlessCore.CommandTopic_Helpers.commandOutcome,
> => {
  let answered = answer->JSON.Decode.array->Option.getOr([])
  cmdJsons->Array.mapWithIndex((cmdJson, i) =>
    switch answered
    ->Array.get(i)
    ->Option.flatMap(ReventlessCore.CommandTopic_Helpers.commandOutcomeOfJson) {
    | Some(outcome) => outcome
    | None => ReventlessCore.CommandTopic_Helpers.Pending({msgId: cmdJson.meta.msgId})
    }
  )
}

let client = ref(None)
let clientOf = () =>
  switch client.contents {
  | Some(c) => c
  | None =>
    let c = AwsSdk.Lambda.client()
    client := Some(c)
    c
  }

/** Sends through the named DCB command Lambda and waits for the outcomes. A failed
    invocation throws, which the slice treats as a failed publish. */
let publishJsonsAndWait = (
  ~functionName: string,
): ReventlessCore.CommandTopic_Helpers.publishJsonsAndWait =>
  async cmdJsons => {
    let output = await AwsSdk.Lambda.InvokeCommand.make({
      functionName,
      payload: cmdJsons->payloadOf->JSON.stringify->NodeBuffer.fromStringUtf8,
    })->AwsSdk.Lambda.InvokeCommand.send(clientOf(), _)
    let text =
      output.payload->Option.mapOr("", bytes =>
        bytes->NodeBuffer.fromBytes->NodeBuffer.toStringUtf8
      )
    switch output.functionError {
    | Some(kind) => JsError.throwWithMessage(`${functionName} failed (${kind}): ${text}`)
    | None => outcomesOf(cmdJsons, JSON.parseOrThrow(text))
    }
  }
