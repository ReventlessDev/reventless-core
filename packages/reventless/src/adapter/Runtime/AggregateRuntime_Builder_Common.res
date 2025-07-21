module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module CommandTopicChannel = CommandTopicChannel
  module EventCollectorChannel = EventCollectorChannel

  type runtimeSpec = {
    aggregate: Pulumi.Resource.t,
    connects: array<Runtime.connect<runtimeParts>>,
    eventCollectorChannelSpec: option<
      EventCollector_Adapter.channelSpec<
        EventCollectorChannel.callbackEvent,
        context,
        EventCollectorChannel.channelParts,
      >,
    >,
    memorySize: int,
    timeout: int,
  }
  type eventHandler = Runtime.eventHandler<RuntimeEnvironment.event, context, unit>

  let runtimeSpecs: dict<runtimeSpec> = Js.Dict.empty()
  let commandGeneratorHandlers: dict<CommandGenerator.eventHandler<context>> = Js.Dict.empty()
  let commandTopicHandlers: dict<eventHandler> = Js.Dict.empty()
  let eventCollectorHandlers: dict<array<eventHandler>> = Js.Dict.empty()

  let aggregateHandler = aggregateName => async (event: RuntimeEnvironment.event, context) => {
    let desc = `aggregateHandler for ${aggregateName}:`
    switch event->CommandGenerator.metaInfo {
    | Some(info) =>
      switch commandGeneratorHandlers->Dict.get(info) {
      | Some(handler) =>
        Js.log2(`----- ${desc} found handler for CommandGenerator`, info)
        await handler(event->CommandGenerator.asPayload, context)
      | None =>
        Js.log2(`${desc} no handler found:`, info)
        ""
      }
    | _ =>
      let _ =
        await event
        ->RuntimeEnvironment.groupBySource
        ->Dict.toArray
        ->Array.map(async ((urn, event)) => {
          switch commandTopicHandlers->Dict.get(urn) {
          | Some(handler) =>
            Js.log2(`----- ${desc} found handler for CommandTopic`, urn)
            await handler(event, context)
          | None =>
            switch eventCollectorHandlers->Dict.get(urn) {
            | Some(handlers) =>
              let count = handlers->Array.length->Int.toString
              Js.log2(`----- ${desc} found ${count} handler(s) for EventCollector`, urn)
              let _ = await handlers->Array.map(handler => handler(event, context))->Promise.all
            | None => Js.log2(`${desc} no handler found:`, urn)
            }
          }
        })
        ->Promise.all
      ""
    }
  }

  let getRuntimeSpec = (aggregate: Pulumi.Resource.t) =>
    runtimeSpecs
    ->Dict.get(aggregate.name->Option.getOr("Unnamed"))
    ->Option.getOr({
      aggregate,
      connects: [],
      eventCollectorChannelSpec: None,
      memorySize: 0,
      timeout: 0,
    })
  let setRuntimeSpec = (aggregate: Pulumi.Resource.t, runtimeSpec) =>
    runtimeSpecs->Dict.set(aggregate.name->Option.getOr("Unnamed"), runtimeSpec)

  let registerRuntimeSpec = (~connect, ~memorySize, ~timeout, aggregate: Pulumi.Resource.t) => {
    let spec = aggregate->getRuntimeSpec
    aggregate->setRuntimeSpec({
      ...spec,
      connects: spec.connects->Array.concat([connect]),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  }

  let registerEventCollectorRuntimeSpec = (
    ~channel,
    ~eventTopics,
    ~resources,
    ~memorySize,
    ~timeout,
    aggregate: Pulumi.Resource.t,
  ) => {
    let spec = aggregate->getRuntimeSpec
    aggregate->setRuntimeSpec({
      ...spec,
      eventCollectorChannelSpec: Some({
        channel,
        eventTopics,
        resources,
      }),
      memorySize: Math.Int.max(spec.memorySize, memorySize),
      timeout: Math.Int.max(spec.timeout, timeout),
    })
  }

  let forCommandGenerator = (
    ~handler: Pulumi.Output.t<CommandGenerator.eventHandler<context>>,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    commandGenerator: CommandGenerator.component,
  ) => {
    let commandGeneratorResource = commandGenerator->Component.toPulumiResource
    let commandGeneratorName = commandGeneratorResource.name->Option.getOr("Unnamed")
    switch commandGeneratorResource.parent {
    | Some(aggregateResource) =>
      aggregateResource->registerRuntimeSpec(~connect, ~memorySize, ~timeout)
      let infos =
        (commandGenerator->Component.outputs).resources
        ->Array.map(resource => resource.info)
        ->Pulumi.Output.all
      let _ =
        (infos, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((infos, handler)) => {
          Js.log2(`***** forCommandGenerator ${commandGeneratorName}: set handler for`, infos)
          infos->Array.map(info => commandGeneratorHandlers->Js.Dict.set(info, handler))
        })

    | None =>
      Js.Exn.raiseError(
        `forCommandGenerator: commandGenerator ${commandGeneratorName} has no Aggregate parent`,
      )
    }
  }

  let forCommandTopic = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    >,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    commandTopic: CommandTopic.component<'op>,
  ) => {
    let commandTopicResource = commandTopic->Component.toPulumiResource
    let commandTopicName = commandTopicResource.name->Option.getOr("Unnamed")
    switch commandTopicResource.parent {
    | Some(aggregateResource) =>
      aggregateResource->registerRuntimeSpec(~connect, ~memorySize, ~timeout)
      let urn = ((commandTopic->Component.outputs).resources->Array.getUnsafe(0)).urn
      let _ =
        (urn, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((urn, handler)) => {
          Js.log(`***** forCommandTopic ${commandTopicName}: set handler for ${urn}`)
          commandTopicHandlers->Js.Dict.set(urn, handler->RuntimeEnvironment.asEventHandler)
        })
    | None =>
      Js.Exn.raiseError(`forCommandTopic: commandTopic ${commandTopicName} has no Aggregate parent`)
    }
  }
  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    >,
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessSpec.Adapter.resource>,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector: EventCollector.component,
  ) => {
    let eventCollectorResource = eventCollector->Component.toPulumiResource
    let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")
    let channel = eventCollector->EventCollector_Adapter.channel
    switch eventCollectorResource.parent->Option.flatMap(parent => parent.parent) {
    | Some(aggregateResource) =>
      aggregateResource->registerEventCollectorRuntimeSpec(
        ~channel,
        ~eventTopics,
        ~resources,
        ~memorySize,
        ~timeout,
      )
      let urns =
        (eventCollector->Component.outputs).resources
        ->Array.map(({urn}) => urn)
        ->Pulumi.Output.all
      let _ =
        (urns, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((urns, handler)) => {
          Js.log2(`***** forEventCollector ${eventCollectorName}: set handler for`, urns)
          // urns->Array.map(urn =>
          //   eventCollectorHandlers->Js.Dict.set(urn, handler->RuntimeEnvironment.asEventHandler)
          // )
          urns->Array.map(urn => {
            let handlers = eventCollectorHandlers->Dict.get(urn)->Option.getOr([])
            eventCollectorHandlers->Dict.set(
              urn,
              handlers->Array.concat([handler->RuntimeEnvironment.asEventHandler]),
            )
          })
        })
    | None =>
      Js.Exn.raiseError(
        `forEventCollector: eventCollector ${eventCollectorName} has no Aggregate parent`,
      )
    }
  }
}
