module Make = (SpecificEventCollector: EventCollector.T): SideEffectHandler.T => {
  let construct = (
    ~sideEffects,
    ~allEventTopics,
    ~queryEngine,
    ~scheduler,
    ~memorySize,
    ~timeout,
    ~policy1,
    ~policy2,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let aggregateNames =
      sideEffects
      ->Belt.Array.map((module(SideEffect: ReventlessSpec.SideEffect.T)) => SideEffect.Source.name)
      ->Belt.Set.String.fromArray

    module Callback = SideEffectHandler_Callback.Make({
      let sideEffects = sideEffects
      let queryEngine = queryEngine
    })
    let eventCollector = SpecificEventCollector.make(
      ~name,
      ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
      ~eventsHandler=Callback.eventsHandler,
      ~memorySize,
      ~timeout,
      ~policy1,
      ~policy2,
      ~opts=Some(opts),
    )
    let eventCollectorResources =
      (eventCollector->Component.extractOutputs).resources->Adapter.resourcesToUnwrappedOutput

    self->Component.setOperations(
      (eventCollector->Component.operations, eventCollectorResources)
      ->Pulumi.Output.all2
      ->Pulumi.Output.apply((({enqueueEvent}, eventCollectorResources)) => {
        SideEffectHandler.enqueueEvent,
        createSchedule: Schedule.create(scheduler, eventCollectorResources),
        deleteSchedule: Schedule.delete(scheduler, eventCollectorResources),
      }),
    )

    self->Component.setOutputs({
      SideEffectHandler.name,
      eventCollector: eventCollector->Component.extractOutputs,
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
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
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
        ~policy1,
        ~policy2,
        ...
      ),
      ~opts=opts->Belt.Option.map(Util.Pulumi.ComponentResourceOptions.ofCustomResourceOptions),
    )
  }
}
