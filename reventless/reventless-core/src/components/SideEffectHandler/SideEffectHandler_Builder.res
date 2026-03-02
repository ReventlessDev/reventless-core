module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  SpecificEventCollector: EventCollector.T,
  EventCollectorRuntimeBuilder: EventCollectorRuntime_Builder.T
    with type EventCollectorChannel.callbackEvent := SpecificEventCollector.callbackEvent,
): SideEffectHandler.T => {
  let construct = (
    ~sideEffects,
    ~allEventTopics,
    ~allCommandTopics,
    ~targets=?,
    ~queryEngine,
    ~scheduler,
    ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
    ~memorySize,
    ~timeout,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let aggregateNames =
      sideEffects
      ->Array.map((module(SideEffect: Reventless.SideEffect.T)) => SideEffect.Source.name)
      ->Belt.Set.String.fromArray

    let eventTopics = allEventTopics->EventTopic.filter(aggregateNames)
    let eventCollector = SpecificEventCollector.make(~name, ~eventTopics, ~opts)

    module Callback = SideEffectHandler_Callback.Make({
      let sideEffects = sideEffects
      let queryEngine = queryEngine
    })
    let handler = SpecificEventCollector.makeHandler(
      ~eventCollector,
      ~jsonEventsHandler=Callback.handleJsonEvents,
    )

    let _ = allCommandTopics->Pulumi.Output.apply(allCommandTopics => {
      let commandTopics =
        targets
        ->Option.map(targets =>
          allCommandTopics->CommandTopic.filter(targets->Set.fromArray)->Dict.valuesToArray
        )
        ->Option.getOr([])
      let resources = commandTopics->Array.flatMap(commandTopic => commandTopic.resources)

      eventCollector->EventCollectorRuntimeBuilder.forEventCollector(
        ~handler,
        ~eventTopics,
        ~resources,
        ~memorySize,
        ~timeout,
      )
    })

    self->Component.setOperations(
      (
        eventCollector->Component.operations,
        (eventCollector->Component.outputs).resources->Adapter.resourcesToResolvedOutput,
      )
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply((({enqueueEvent}, eventCollectorResources)) => {
        SideEffectHandler.enqueueEvent,
        createSchedule: ScheduleOps.create(
          ~scheduler,
          ~channelResources=eventCollectorResources,
          ~resourceNaming,
        ),
        deleteSchedule: ScheduleOps.delete(
          ~scheduler,
          ~channelResources=eventCollectorResources,
          ~resourceNaming,
        ),
      }),
    )

    self->Component.setOutputs({
      SideEffectHandler.name,
      eventCollector: eventCollector->Component.outputs,
    })
  }

  let make = (
    ~name,
    ~sideEffects,
    ~allEventTopics,
    ~allCommandTopics,
    ~targets=?,
    ~queryEngine,
    ~scheduler,
    ~resourceNaming,
    ~memorySize=2048,
    ~timeout=180,
    ~opts=?,
  ) => {
    Component.make(
      ~componentType=SideEffectHandler.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(
        ~sideEffects,
        ~allEventTopics,
        ~allCommandTopics,
        ~targets?,
        ~queryEngine,
        ~scheduler,
        ~resourceNaming,
        ~memorySize,
        ~timeout,
        ...
      ),
      ~opts,
    )
  }
}
