module Make = (
  RuntimeEnvironment: Runtime.Environment,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
) => {
  let log = Logger.fromEnv()
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
  type effectHandler = Runtime.effectHandler<RuntimeEnvironment.event, context, unit, string>

  let runtimeSpecs: dict<runtimeSpec> = Dict.make()
  let commandGeneratorHandlers: dict<CommandGenerator.effectEventHandler<context>> = Dict.make()
  let commandTopicHandlers: dict<effectHandler> = Dict.make()
  let eventCollectorHandlers: dict<array<effectHandler>> = Dict.make()

  let aggregateHandler = aggregateName =>
    async (event: RuntimeEnvironment.event, context) => {
      let correlationId = event->RuntimeEnvironment.extractCorrelationId
      let causationId = event->RuntimeEnvironment.extractCausationId
      let comp = `AggregateRuntime(${aggregateName})`
      // Shared dispatch helper (Runtime.runEffect) annotates correlationId / comp /
      // causationId onto the invocation so the application handler's own log lines
      // carry them without re-logging by hand.
      let runEffect = effect => Runtime.runEffect(~correlationId?, ~causationId?, ~comp, effect)
      switch event->CommandGenerator.metaInfo {
      | Some(info) =>
        switch commandGeneratorHandlers->Dict.get(info) {
        | Some(handler) =>
          EffectLogger.logDebug(~comp, `found CommandGenerator handler for ${info}`)->Effect.runSync
          let _ = await runEffect(handler(event->CommandGenerator.asPayload, context))
        | None =>
          let available = commandGeneratorHandlers->Dict.keysToArray->Array.join(",")
          EffectLogger.logWarn(
            ~comp,
            `no handler found: ${info} available=[${available}]`,
          )->Effect.runSync
        }
      | _ =>
        let _ = await event
        ->RuntimeEnvironment.groupBySource
        ->Dict.toArray
        ->Array.map(async ((urn, event)) => {
          switch commandTopicHandlers->Dict.get(urn) {
          | Some(handler) =>
            EffectLogger.logDebug(~comp, `found CommandTopic handler for ${urn}`)->Effect.runSync
            await runEffect(handler(event, context))
          | None =>
            switch eventCollectorHandlers->Dict.get(urn) {
            | Some(handlers) =>
              let count = handlers->Array.length->Int.toString
              EffectLogger.logDebug(
                ~comp,
                `found ${count} EventCollector handler(s) for ${urn}`,
              )->Effect.runSync
              let _ = await handlers
              ->Array.map(handler => runEffect(handler(event, context)))
              ->Promise.all
            | None =>
              let available =
                Array.concat(
                  commandTopicHandlers->Dict.keysToArray,
                  eventCollectorHandlers->Dict.keysToArray,
                )->Array.join(",")
              EffectLogger.logWarn(
                ~comp,
                `no handler found: ${urn} available=[${available}]`,
              )->Effect.runSync
            }
          }
        })
        ->Promise.all
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
    ~handler: Pulumi.Output.t<CommandGenerator.effectEventHandler<context>>,
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
        ->Array.map(resource => resource.resourceInfo)
        ->Pulumi.Output.all
      let _ =
        (infos, handler)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply(((infos, handler)) => {
          let infoStrs = infos->Array.filterMap(ri => switch ri {
            | ReventlessInfra.Adapter.ApiResolver({typeName, fieldName}) => Some(`${typeName}.${fieldName}`)
            | _ => None
          })
          log.debug(
            ~comp="AggregateRuntime",
            `forCommandGenerator ${commandGeneratorName}: set handler for ${infoStrs->Array.join(", ")}`,
          )
          infoStrs->Array.map(info => commandGeneratorHandlers->Dict.set(info, handler))
        })

    | None =>
      JsError.throwWithMessage(
        `forCommandGenerator: commandGenerator ${commandGeneratorName} has no Aggregate parent`,
      )
    }
  }

  let forCommandTopic = (
    ~handler: Pulumi.Output.t<
      Runtime.effectHandler<CommandTopicChannel.callbackEvent, context, unit, string>,
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
          log.debug(
            ~comp="AggregateRuntime",
            `forCommandTopic ${commandTopicName}: set handler for ${urn}`,
          )
          commandTopicHandlers->Dict.set(urn, handler->RuntimeEnvironment.asEffectHandler)
        })
    | None =>
      JsError.throwWithMessage(
        `forCommandTopic: commandTopic ${commandTopicName} has no Aggregate parent`,
      )
    }
  }
  let forEventCollector = (
    ~handler: Pulumi.Output.t<
      Runtime.effectHandler<EventCollectorChannel.callbackEvent, context, unit, string>,
    >,
    ~eventTopics: EventTopic.allOutputs,
    ~resources: array<ReventlessInfra.Adapter.resource>,
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
          log.debug(
            ~comp="AggregateRuntime",
            `forEventCollector ${eventCollectorName}: set handler for ${urns->Array.join(", ")}`,
          )
          urns->Array.map(urn => {
            let handlers = eventCollectorHandlers->Dict.get(urn)->Option.getOr([])
            eventCollectorHandlers->Dict.set(
              urn,
              handlers->Array.concat([handler->RuntimeEnvironment.asEffectHandler]),
            )
          })
        })
    | None =>
      JsError.throwWithMessage(
        `forEventCollector: eventCollector ${eventCollectorName} has no Aggregate parent`,
      )
    }
  }
}
