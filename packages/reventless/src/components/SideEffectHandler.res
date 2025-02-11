module ReventlessEventCollector = EventCollector

let componentType = ComponentType.SideEffectHandler

type t
type outputs = {name: string, eventCollector: EventCollector.outputs}
type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  createSchedule: ReventlessSpec.Schedule.create,
  deleteSchedule: ReventlessSpec.Schedule.delete,
}
type component = Component.t<t, outputs, operations>

type sideEffects = array<module(ReventlessSpec.SideEffect.T)>

module type T = {
  let make: (
    ~name: string,
    ~sideEffects: sideEffects,
    ~allEventTopics: EventTopic.allOutputs,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    ~scheduler: Scheduler.operations,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => component
}

module Make = (SpecificEventCollector: EventCollector.T): T => {
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

    module Runtime = SideEffectHandler_Runtime
    let eventCollector = SpecificEventCollector.make(
      ~name,
      ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
      ~eventsHandler=Runtime.eventsHandler(sideEffects, queryEngine, ...),
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
        enqueueEvent,
        createSchedule: Schedule.create(scheduler, eventCollectorResources),
        deleteSchedule: Schedule.delete(scheduler, eventCollectorResources),
      }),
    )

    self->Component.setOutputs({name, eventCollector: eventCollector->Component.extractOutputs})
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
      ~componentType=componentType->ComponentType.toString,
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
