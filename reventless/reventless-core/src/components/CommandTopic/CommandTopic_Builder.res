module Make = (Spec: Reventless.CommandTopic.T, Channel: CommandTopic_Adapter.Channel): (
  CommandTopic.T with module Spec = Spec and type callbackEvent = Channel.callbackEvent
) => {
  module Spec = Spec
  type callbackEvent = Channel.callbackEvent

  type commandsHandler = CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type publish = CommandTopic.publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: CommandTopic.publishJsons,
  }
  type component = Component.t<CommandTopic.t, CommandTopic.outputs, operations>

  // Helper to extract type name from JSON command using TAG field
  let extractTypeNameFromJson = json => {
    switch json {
    | JSON.Object(dict) =>
      switch dict->Dict.get("TAG") {
      | Some(JSON.String(tag)) => tag
      | _ => ""
      }
    | _ => ""
    }
  }

  // Filtering handler that routes commands to registered handlers via global registry.
  // Defined at module level so it can be referenced by makeFilteringHandler.
  let filteringHandler: CommandTopic.jsonCommandsHandler = async jsonItems => {
    let allResults = []

    let processItem = async item => {
      let {Reventless.CommandTopic.reference: reference, command: json} = item
      let typeName = extractTypeNameFromJson(json)

      // Look up handlers for this command type in the global registry
      let handlers = CommandTopic.getHandlers(typeName)

      // Call each registered handler
      let handlerPromises = handlers->Array.map(async handlerEntry => {
        let {CommandTopic.handler: handler} = handlerEntry
        try {
          let results = await handler([{Reventless.CommandTopic.reference, command: json}])
          allResults->Array.pushMany(results)
        } catch {
        | _ => () // Skip if handler fails
        }
      })
      let _ = await Promise.all(handlerPromises)
    }

    let itemPromises = jsonItems->Array.map(async item => {
      let _ = await processItem(item)
    })
    let _ = await Promise.all(itemPromises)

    allResults
  }

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(CommandTopic.componentType)

    let channel = Channel.make(~name, ~opts)
    self->CommandTopic_Adapter.setChannel(channel)

    self->Component.setOperations(
      channel.publishJsons->Pulumi.Output.apply(publishJsons => {
        module Ops = {
          let publishJsons = publishJsons
        }
        module Operations = CommandTopic_Operations.Make(Spec, Ops)

        {
          publish: Operations.publish,
          publishJsons: Operations.publishJsons,
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
