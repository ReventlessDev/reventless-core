module Make = (
  SpecificEventCollector: EventCollector.T,
  RuntimeEnvironment: Runtime.Environment,
): SideEffectHandler.T => {
  let construct = (
    ~sideEffects,
    ~allEventTopics,
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
      ->Belt.Array.map((module(SideEffect: ReventlessSpec.SideEffect.T)) => SideEffect.Source.name)
      ->Belt.Set.String.fromArray

    let eventCollector = SpecificEventCollector.make(~name, ~opts)
    let opts = {Pulumi.ComponentResource.parent: eventCollector->Component.toPulumiResource}

    module Callback = SideEffectHandler_Callback.Make({
      let sideEffects = sideEffects
      let queryEngine = queryEngine
    })
    let handler = SpecificEventCollector.makeHandler(
      ~eventCollector,
      ~eventsHandler=Callback.eventsHandler,
    )
    let runtime = RuntimeEnvironment.make(
      ~name,
      ~handler,
      ~memorySize,
      ~timeout,
      ~opts,
    )

    SpecificEventCollector.subscribe(
      ~name,
      ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
      ~eventCollector,
      ~runtime,
      ~opts,
    )

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
        ~queryEngine,
        ~scheduler,
        ~memorySize,
        ~timeout,
        ...
      ),
      ~opts=opts->Belt.Option.map(Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions)
    )
  }
}
