// In-memory CommandTopic channel.
// publishJsons encodes each command as {id, meta, command} (full message body) and dispatches via Bus.
// connect wires the channel to the runtime handler via Bus.registerCommandHandler.
// The full body format matches what CommandTopic_Callback.handleJsonCommands expects to decode.

module Make = (Bus: InMemory_Bus.T) => {
  type callbackEvent = JSON.t
  type runtimeParts = RuntimeEnvironment_InMemory.parts
  type channelParts = {name: string}

  // Encode the full message body that CommandTopic_Callback expects:
  // {id: string, meta: ..., command: commandPayload}
  let encodeMessage = (cmdJson: Reventless.Message.commandJson): JSON.t =>
    JSON.Encode.object(
      Dict.fromArray([
        ("id", JSON.Encode.string(cmdJson.id)),
        (
          "meta",
          cmdJson.meta->S.reverseConvertToJsonOrThrow(Reventless.Message.metaSchema),
        ),
        ("command", cmdJson.commandJson),
      ]),
    )

  // Extract aggregate id (used as reference) from the full message body
  let decodeId = (body: JSON.t): string =>
    switch body {
    | JSON.Object(d) =>
      d
      ->Dict.get("id")
      ->Option.flatMap(j =>
        switch j {
        | JSON.String(s) => Some(s)
        | _ => None
        }
      )
      ->Option.getOr("")
    | _ => ""
    }

  let make: ReventlessCore.CommandTopic_Adapter.channelMaker<
    callbackEvent,
    'context,
    channelParts,
    runtimeParts,
  > = (~name, ~opts as _=?) => {
    let publishJsons: ReventlessInfra.CommandTopic.publishJsons = async jsons => {
      let _ =
        await jsons
        ->Array.map(async (cmdJson: Reventless.Message.commandJson) => {
          await Bus.dispatchCommand(name, encodeMessage(cmdJson))
        })
        ->Promise.all
    }

    let publishJsonsStream: ReventlessInfra.CommandTopic.publishJsonsStream = stream =>
      stream
      ->Stream.grouped(10)
      ->Stream.runForEach(jsons =>
        Effect.promise(() => publishJsons(jsons))
      )

    let handleChannelEvent = (
      handleCmds: ReventlessCore.CommandTopic.jsonCommandsHandler,
    ): Pulumi.Output.t<ReventlessCore.Runtime.effectHandler<callbackEvent, 'context, unit, string>> =>
      (
        (fullBody: JSON.t, _ctx) => {
          // Pass the full body as `command` — that's what handleJsonCommands decodes
          let reference = decodeId(fullBody)
          let item: ReventlessInfra.CommandTopic.topicItem<JSON.t> = {command: fullBody, reference}
          handleCmds(Stream.fromIterable([item]))->Effect.map(_ => ())
        }
      )->Pulumi.Output.make

    let connect: ReventlessCore.CommandTopic_Adapter.connect<
      callbackEvent,
      'context,
      channelParts,
      runtimeParts,
    > = (~name as _, ~channel, ~runtime, ~resources as _, ~opts as _) => {
      Bus.registerCommandHandler(channel.parts.name, async (json, ctx) => {
        let handler =
          await runtime.parts.handlerDeferred->Deferred.await_->Effect.runPromise
        await handler(json, ctx)
      })
      []
    }

    {
      parts: {name: name},
      resources: [],
      publishJsons: publishJsons->Pulumi.Output.make,
      publishJsonsStream: publishJsonsStream->Pulumi.Output.make,
      handleChannelEvent,
      connect,
    }
  }
}
