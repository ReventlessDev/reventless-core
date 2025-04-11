module Make = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  SpecificEventCollector: EventCollector.T,
  PluginRuntimeBuilder: PluginRuntime_Builder.T
    with type EventCollectorChannel.callbackEvent := SpecificEventCollector.callbackEvent,
): SideEffectHandler.T => {
  let construct = (
    ~sideEffects,
    ~allEventTopics,
    ~allCommandTopics,
    ~targets=?,
    ~queryEngine,
    ~scheduler,
    ~memorySize,
    ~timeout,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let aggregateNames =
      sideEffects
      ->Array.map((module(SideEffect: ReventlessSpec.SideEffect.T)) => SideEffect.Source.name)
      ->Belt.Set.String.fromArray

    let eventTopics = allEventTopics->EventTopic.filter(aggregateNames)
    let eventCollector = SpecificEventCollector.make(~name, ~eventTopics, ~opts)
    let opts = {Pulumi.ComponentResource.parent: eventCollector->Component.toPulumiResource}

    module Callback = SideEffectHandler_Callback.Make({
      let sideEffects = sideEffects
      let queryEngine = queryEngine
    })
    let handler = SpecificEventCollector.makeHandler(
      ~eventCollector,
      ~eventsHandler=Callback.eventsHandler,
    )
    let runtime =
      eventCollector->PluginRuntimeBuilder.forSideEffectHandlerEventCollector(
        ~handler,
        ~memorySize,
        ~timeout,
      )

    let _ = allCommandTopics->Pulumi.Output.apply(allCommandTopics => {
      let commandTopics =
        targets
        ->Option.map(targets =>
          allCommandTopics->CommandTopic.filter(targets->Set.fromArray)->Dict.valuesToArray
        )
        ->Option.getOr([])
      let resources = commandTopics->Array.flatMap(commandTopic => commandTopic.resources)

      SpecificEventCollector.connect(
        ~name,
        ~eventTopics,
        ~eventCollector,
        ~runtime,
        ~resources,
        ~opts,
      )
    })

    self->Component.setOperations(
      (
        eventCollector->Component.operations,
        (eventCollector->Component.outputs).resources->Adapter.resourcesToUnwrappedOutput,
      )
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply((({enqueueEvent}, eventCollectorResources)) => {
        SideEffectHandler.enqueueEvent,
        createSchedule: Schedule.create(scheduler, eventCollectorResources),
        deleteSchedule: Schedule.delete(scheduler, eventCollectorResources),
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
        ~memorySize,
        ~timeout,
        ...
      ),
      ~opts=opts->Option.map(Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions)
    )
  }
}
