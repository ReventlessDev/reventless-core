module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
): (
  AggregateRuntime_Builder.T
    with type context = RuntimeEnvironment.context
    and type parts = RuntimeEnvironment.parts
    and module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
) => {
  type context = RuntimeEnvironment.context
  type parts = RuntimeEnvironment.parts
  module CommandTopicChannel = CommandTopicChannel
  module EventCollectorChannel = EventCollectorChannel

  let aggregateRuntimes = Js.Dict.empty()
  let commandGeneratorHandlers = Js.Dict.empty()
  let commandTopicHandlers = Js.Dict.empty()
  let eventCollectorHandlers = Js.Dict.empty()

  let aggregateHandler = aggregateName => async (event, context) =>
    Js.log4(
      "AggregateRuntime_Builder_PerAggregate.aggregateHandler:",
      aggregateName,
      event,
      context,
    )

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
    ~handler: Pulumi.Output.t<CommandGenerator.eventHandler<context>>,
    ~memorySize=1024,
    ~timeout=30,
    commandGenerator: CommandGenerator.component,
  ) => {
    let commandGeneratorResource = commandGenerator->Component.toPulumiResource
    let commandGeneratorName = commandGeneratorResource.name->Option.getOr("Unnamed")
    switch commandGeneratorResource.parent {
    | Some(aggregate) =>
      let aggregateName = aggregate.name->Option.getExn
      commandGeneratorHandlers->Js.Dict.set(aggregateName, handler)
      aggregate->runtimeForAggregate(~memorySize, ~timeout)
    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_ForAggregate.forCommandGenerator: commandGenerator ${commandGeneratorName} has no Aggregate parent`,
      )
    }
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
      let aggregateName = aggregateResource.name->Option.getExn
      commandTopicHandlers->Js.Dict.set(aggregateName, handler)
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
      let aggregateName = aggregateResource.name->Option.getExn
      eventCollectorHandlers->Js.Dict.set(aggregateName, handler)
      aggregateResource->runtimeForAggregate(~memorySize, ~timeout)
    | None =>
      Js.Exn.raiseError(
        `AggregateRuntime_Builder_ForAggregate.forEventCollector: eventCollector ${eventCollectorName} has no Aggregate parent`,
      )
    }
  }
}
