module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
): (
  AggregateRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type runtimeParts = RuntimeEnvironment.parts
    and module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type runtimeParts = RuntimeEnvironment.parts
  module CommandTopicChannel = CommandTopicChannel
  module EventCollectorChannel = EventCollectorChannel

  let aggregateRuntimes = Js.Dict.empty()
  let commandGeneratorHandlers = Js.Dict.empty()
  let commandTopicHandlers = Js.Dict.empty()
  let eventCollectorHandlers = Js.Dict.empty()

  let aggregateHandler = aggregateName => async (event: RuntimeEnvironment.event, context) => {
    Js.log4(
      "----- AggregateRuntime_Builder_PerAggregate.aggregateHandler:",
      aggregateName,
      event,
      context,
    )
    switch event->CommandGenerator.metaInfo {
    | Some(info) =>
      switch commandGeneratorHandlers->Js.Dict.get(info) {
      | Some(handler) =>
        Js.log2(
          "----- AggregateRuntime_Builder_PerAggregate.aggregateHandler: found handler for commandGenerator",
          info,
        )
        await handler(event->CommandGenerator.asPayload, context)
      | None =>
        Js.log2("AggregateRuntime_Builder_PerAggregate.aggregateHandler: no handler found:", info)
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
            Js.log2(
              "----- AggregateRuntime_Builder_PerAggregate.aggregateHandler: found handler for commandTopic",
              urn,
            )
            await handler(event, context)
          | None =>
            switch eventCollectorHandlers->Js.Dict.get(urn) {
            | Some(handler) =>
              Js.log2(
                "----- AggregateRuntime_Builder_PerAggregate.aggregateHandler: found handler for eventCollector",
                urn,
              )
              await handler(event, context)
            | None =>
              Js.log2(
                "AggregateRuntime_Builder_PerAggregate.aggregateHandler: no handler found:",
                urn,
              )
            }
          }
        })
        ->Promise.all
      ""
    }
  }

  let runtimeForAggregate = (~memorySize=?, ~timeout=?, aggregate: Pulumi.Resource.t) => {
    let aggregateName = aggregate.name->Option.getOr("")
    switch aggregateRuntimes->Js.Dict.get(aggregateName) {
    | Some(runtime) => runtime
    | None =>
      let runtime = RuntimeEnvironment.make(
        ~name=aggregateName->ComponentType.name(CommandGenerator.componentType),
        ~handler=aggregateHandler(aggregateName)->Pulumi.Output.make,
        ~memorySize?,
        ~timeout?,
        ~opts={Pulumi.ComponentResource.parent: aggregate},
      )
      aggregateRuntimes->Js.Dict.set(aggregateName, runtime)
      runtime
    }
  }

  let forCommandGenerator = (
    ~handler as _: Pulumi.Output.t<CommandGenerator.eventHandler<context>>,
    ~memorySize=1024,
    ~timeout=30,
    commandGenerator: CommandGenerator.component,
  ) => {
    let commandGeneratorResource = commandGenerator->Component.toPulumiResource
    let commandGeneratorName = commandGeneratorResource.name->Option.getOr("Unnamed")
    switch commandGeneratorResource.parent {
    | Some(aggregate) => aggregate->runtimeForAggregate(~memorySize, ~timeout)
    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_ForAggregate.forCommandGenerator: commandGenerator ${commandGeneratorName} has no Aggregate parent`,
      )
    }
  }

  let registerCommandGeneratorHandler = (
    ~handler: Pulumi.Output.t<CommandGenerator.eventHandler<context>>,
    commandGenerator: CommandGenerator.component,
  ) => {
    let commandGeneratorResource = commandGenerator->Component.toPulumiResource
    let commandGeneratorName = commandGeneratorResource.name->Option.getOr("Unnamed")
    let infos =
      (commandGenerator->Component.outputs).resources
      ->Array.map(resource => resource.info)
      ->Pulumi.Output.all
    let _ =
      (infos, handler)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply(((infos, handler)) => {
        Js.log2(
          `***** AggregateRuntime_Builder_ForAggregate.forCommandGenerator ${commandGeneratorName}: set handler for`,
          infos,
        )
        infos->Array.map(info => commandGeneratorHandlers->Js.Dict.set(info, handler))
      })
  }

  let forCommandTopic = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<CommandTopicChannel.callbackEvent, context, unit>,
    >,
    ~memorySize=1024,
    ~timeout=30,
    commandTopic: CommandTopic.component<'op>,
  ) => {
    let commandTopicResource = commandTopic->Component.toPulumiResource
    let commandTopicName = commandTopicResource.name->Option.getOr("Unnamed")
    switch commandTopicResource.parent {
    | Some(aggregateResource) =>
      let _ =
        (commandTopicResource.urn, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((urn, handler)) => {
          Js.log(
            `***** AggregateRuntime_Builder_ForAggregate.forCommandTopic ${commandTopicName}: set handler for ${urn}`,
          )
          commandTopicHandlers->Js.Dict.set(urn, handler->RuntimeEnvironment.asEventHandler)
        })
      aggregateResource->runtimeForAggregate(~memorySize, ~timeout)
    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_ForAggregate.forCommandTopic: commandTopic ${commandTopicName} has no Aggregate parent`,
      )
    }
  }
  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.eventHandler<EventCollectorChannel.callbackEvent, context, unit>,
    >,
    ~memorySize=1024,
    ~timeout=30,
    eventCollector: EventCollector.component,
  ) => {
    let eventCollectorResource = eventCollector->Component.toPulumiResource
    let eventCollectorName = eventCollectorResource.name->Option.getOr("Unnamed")
    switch eventCollectorResource.parent {
    | Some(aggregateResource) =>
      let _ = eventCollectorResource.urn->Pulumi.Output.apply(urn => {
        Js.log(
          `***** AggregateRuntime_Builder_ForAggregate.forEventCollector ${eventCollectorName}: set handler for ${urn}`,
        )
        eventCollectorHandlers->Js.Dict.set(urn, handler->RuntimeEnvironment.asEventHandler)
      })
      aggregateResource->runtimeForAggregate(~memorySize, ~timeout)
    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_ForAggregate.forEventCollector: eventCollector ${eventCollectorName} has no Aggregate parent`,
      )
    }
  }
}
