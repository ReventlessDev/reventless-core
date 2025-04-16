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
    memorySize: int,
    timeout: int,
  }

  let aggregateRuntimeSpecs = Js.Dict.empty()
  let commandGeneratorHandlers = Js.Dict.empty()
  let commandTopicHandlers = Js.Dict.empty()
  let eventCollectorHandlers = Js.Dict.empty()

  let aggregateHandler = aggregateName => async (event: RuntimeEnvironment.event, context) => {
    let desc = `AggregateRuntime_Builder_PerAggregate.aggregateHandler for ${aggregateName}:`
    switch event->CommandGenerator.metaInfo {
    | Some(info) =>
      switch commandGeneratorHandlers->Js.Dict.get(info) {
      | Some(handler) =>
        Js.log2(`----- ${desc} found handler for commandGenerator`, info)
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
          switch commandTopicHandlers->Js.Dict.get(urn) {
          | Some(handler) =>
            Js.log2(`----- ${desc} found handler for commandTopic`, urn)
            await handler(event, context)
          | None =>
            switch eventCollectorHandlers->Js.Dict.get(urn) {
            | Some(handler) =>
              Js.log2(`----- ${desc} found handler for eventCollector`, urn)
              await handler(event, context)
            | None => Js.log2(`${desc} no handler found:`, urn)
            }
          }
        })
        ->Promise.all
      ""
    }
  }

  let registerRuntimeSpec = (~connect, ~memorySize, ~timeout, aggregate: Pulumi.Resource.t) => {
    let aggregateName = aggregate.name->Option.getOr("Unnamed")
    let spec =
      aggregateRuntimeSpecs
      ->Dict.get(aggregateName)
      ->Option.getOr({aggregate, connects: [], memorySize: 0, timeout: 0})
    aggregateRuntimeSpecs->Js.Dict.set(
      aggregateName,
      {
        aggregate,
        connects: spec.connects->Array.concat([connect]),
        memorySize: Math.Int.max(spec.memorySize, memorySize),
        timeout: Math.Int.max(spec.timeout, timeout),
      },
    )
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
          Js.log2(
            `***** AggregateRuntime_Builder_PerAggregate.forCommandGenerator ${commandGeneratorName}: set handler for`,
            infos,
          )
          infos->Array.map(info => commandGeneratorHandlers->Js.Dict.set(info, handler))
        })

    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_PerAggregate.forCommandGenerator: commandGenerator ${commandGeneratorName} has no Aggregate parent`,
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
          Js.log(
            `***** AggregateRuntime_Builder_PerAggregate.forCommandTopic ${commandTopicName}: set handler for ${urn}`,
          )
          commandTopicHandlers->Js.Dict.set(urn, handler->RuntimeEnvironment.asEventHandler)
        })
    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_PerAggregate.forCommandTopic: commandTopic ${commandTopicName} has no Aggregate parent`,
      )
    }
  }
  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    >,
    ~connect,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector: EventCollector.component,
  ) => {
    let eventCollectorResource = eventCollector->Component.toPulumiResource
    let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")
    switch eventCollectorResource.parent {
    | Some(aggregateResource) =>
      aggregateResource->registerRuntimeSpec(~connect, ~memorySize, ~timeout)
      let urns =
        (eventCollector->Component.outputs).resources
        ->Array.map(({urn}) => urn)
        ->Pulumi.Output.all
      let _ =
        (urns, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((urns, handler)) => {
          Js.log2(
            `***** AggregateRuntime_Builder_PerAggregate.forEventCollector ${eventCollectorName}: set handler for`,
            urns,
          )
          urns->Array.map(urn =>
            eventCollectorHandlers->Js.Dict.set(urn, handler->RuntimeEnvironment.asEventHandler)
          )
        })
    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_PerAggregate.forEventCollector: eventCollector ${eventCollectorName} has no Aggregate parent`,
      )
    }
  }
}
