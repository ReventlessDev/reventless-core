module Make = (Spec: ReventlessInfra.CommandTopic.T, Channel: CommandTopic_Adapter.Channel): (
  CommandTopic.T with module Spec = Spec and type callbackEvent = Channel.callbackEvent
) => {
  module Spec = Spec
  type callbackEvent = Channel.callbackEvent

  type commandsHandler = CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type publish = CommandTopic.publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: CommandTopic.publishJsons,
    publishJsonsStream: CommandTopic.publishJsonsStream,
  }
  type component = Component.t<CommandTopic.t, CommandTopic.outputs, operations>

  // Helper to extract type name from JSON command using TAG field.
  // Handles both direct command JSON (TAG at top level) and full message
  // body from publishJsons (TAG nested inside "command" field).
  let extractTypeNameFromJson = json => {
    switch json {
    | JSON.Object(dict) =>
      switch dict->Dict.get("TAG") {
      | Some(JSON.String(tag)) => tag
      | _ =>
        // TAG is nested inside "command" when message comes via publishJsons → bus
        switch dict->Dict.get("command") {
        | Some(JSON.Object(cmdDict)) =>
          switch cmdDict->Dict.get("TAG") {
          | Some(JSON.String(tag)) => tag
          | _ => ""
          }
        | _ => ""
        }
      }
    | _ => ""
    }
  }

  // Filtering handler that routes commands to registered handlers via global registry.
  // Defined at module level so it can be referenced by makeFilteringHandler.
  let filteringHandler: CommandTopic.jsonCommandsHandler = stream =>
    stream
    ->Stream.mapEffect(item => {
      let {ReventlessInfra.CommandTopic.reference: reference, command: json} = item
      let typeName = extractTypeNameFromJson(json)
      let handlers = CommandTopic.getHandlers(typeName)
      Effect.promise(async () => {
        let allResults: array<result<string, string>> = []
        let _ =
          await handlers
          ->Array.map(async handlerEntry => {
            let {CommandTopic.handler: handler} = handlerEntry
            try {
              let results =
                await handler(
                  Stream.fromIterable([{ReventlessInfra.CommandTopic.reference, command: json}]),
                )->Effect.runPromise
              allResults->Array.pushMany(results)
            } catch {
            | _ => () // Skip if handler fails
            }
          })
          ->Promise.all
        allResults
      })
    })
    ->Stream.runCollect
    ->Effect.map(Array.flat)

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(CommandTopic.componentType)

    let channel = Channel.make(~name, ~opts)
    self->CommandTopic_Adapter.setChannel(channel)

    self->Component.setOperations(
      (channel.publishJsons, channel.publishJsonsStream)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((publishJsons, publishJsonsStream)) => {
        module Ops = {
          let publishJsons = publishJsons
        }
        module Operations = CommandTopic_Operations.Make(Spec, Ops)

        {
          publish: Operations.publish,
          publishJsons: Operations.publishJsons,
          publishJsonsStream: publishJsonsStream,
        }
      }),
    )

    let outputs: CommandTopic.outputs = {
      resources: channel.resources,
    }
    self->Component.setOutputs(outputs)
  }

  let connect = (~runtime, ~resources, commandTopic) => {
    let commandTopicResource = commandTopic->Component.toPulumiResource
    let name =
      commandTopicResource.name
      ->Option.getOr("Unnamed")
      ->ComponentType.name(CommandTopic.componentType)
    let opts = {Pulumi.ComponentResource.parent: commandTopicResource}
    let channel = commandTopic->CommandTopic_Adapter.channel

    let _connectResources = channel.connect(~name, ~channel, ~runtime, ~resources, ~opts)
  }

  let registerHandler = (~commandTopic as _, ~schema, ~handler, ~typeNames) => {
    // Delegate to global registry
    CommandTopic.registerHandler(~schema, ~handler, ~typeNames)
  }

  let makeHandler = (~commandTopic, ~commandsHandler: commandsHandler) => {
    let channel = commandTopic->CommandTopic_Adapter.channel
    module CallbackOps = {
      module Spec = Spec
      let commandsHandler = commandsHandler
    }
    module Callback = CommandTopic_Callback.Make(Spec, CallbackOps)

    channel.handleChannelEvent(Callback.handleJsonCommands)
  }

  // Returns the filtering handler output for runtime connection.
  // This is the entry point for the shared DCB command topic Lambda.
  let makeFilteringHandler = commandTopic => {
    let channel = commandTopic->CommandTopic_Adapter.channel
    channel.handleChannelEvent(filteringHandler)
  }

  let make = (~name, ~opts=?): component =>
    Component.make(
      ~componentType=CommandTopic.componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
    )
}
