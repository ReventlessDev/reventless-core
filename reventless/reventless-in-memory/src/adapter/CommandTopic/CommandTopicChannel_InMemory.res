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
  let encodeMessage = (cmdJson: ReventlessSpec.Message.commandJson): JSON.t =>
    JSON.Encode.object(
      Dict.fromArray([
        ("id", JSON.Encode.string(cmdJson.id)),
        (
          "meta",
          cmdJson.meta->S.reverseConvertToJsonOrThrow(ReventlessSpec.Message.metaSchema),
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

  let make: Reventless.CommandTopic_Adapter.channelMaker<
    callbackEvent,
    'context,
    channelParts,
    runtimeParts,
  > = (~name, ~opts as _=?) => {
    let publishJsons: ReventlessSpec.CommandTopic.publishJsons = async jsons => {
      let _ =
        await jsons
        ->Array.map(async (cmdJson: ReventlessSpec.Message.commandJson) => {
          await Bus.dispatchCommand(name, encodeMessage(cmdJson))
        })
        ->Promise.all
    }

    let handleChannelEvent = (
      handleCmds: Reventless.CommandTopic.jsonCommandsHandler,
    ): Pulumi.Output.t<Reventless.Runtime.eventHandler<callbackEvent, 'context, unit>> =>
      (
        (fullBody: JSON.t, _ctx) => {
          // Pass the full body as `command` — that's what handleJsonCommands decodes
          let reference = decodeId(fullBody)
          handleCmds([{command: fullBody, reference}])->Promise.thenResolve(_ => ())
        }
      )->Pulumi.Output.make

    let connect: Reventless.CommandTopic_Adapter.connect<
      callbackEvent,
      'context,
      channelParts,
      runtimeParts,
    > = (~name as _, ~channel, ~runtime, ~resources as _, ~opts as _) => {
      Bus.registerCommandHandler(channel.parts.name, (json, ctx) =>
        switch runtime.parts.handlerRef.contents {
        | Some(h) => h(json, ctx)
        | None =>
          Console.log2("InMemory CommandTopic: handler not registered for", channel.parts.name)
          Promise.resolve()
        }
      )
      []
    }

    {
      parts: {name: name},
      resources: [],
      publishJsons: publishJsons->Pulumi.Output.make,
      handleChannelEvent,
      connect,
    }
  }
}
