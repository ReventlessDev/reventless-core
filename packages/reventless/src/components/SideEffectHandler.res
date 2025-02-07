module ReventlessEventCollector = EventCollector

let componentType = ComponentType.SideEffectHandler

type outputs = {name: string, eventCollector: EventCollector.outputs}

type t
type component = Component.t<t, outputs, unit>

type sideEffects = array<module(ReventlessSpec.SideEffect.T)>

module type T = {
  let make: (
    ~name: string,
    ~sideEffects: sideEffects,
    ~allEventTopics: EventTopic.allOutputs,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~scheduler: Scheduler.operations,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~policy1: Pulumi.Output.t<option<string>>,
    ~policy2: Pulumi.Output.t<option<string>>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => component

  let enqueueEvent: component => Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent>
  let createSchedule: component => Pulumi.Output.t<ReventlessSpec.Schedule.create>
  let deleteSchedule: component => Pulumi.Output.t<ReventlessSpec.Schedule.delete>
}

module Make = (EventCollector: EventCollector.T): T => {
  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setEnqueueEvent: (
    component,
    Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent>,
  ) => unit = "enqueueEvent"
  @get
  external enqueueEvent: component => Pulumi.Output.t<ReventlessSpec.EventCollector.enqueueEvent> =
    "enqueueEvent"

  @set
  external setCreateSchedule: (component, Pulumi.Output.t<ReventlessSpec.Schedule.create>) => unit =
    "createSchedule"
  @get
  external createSchedule: component => Pulumi.Output.t<ReventlessSpec.Schedule.create> =
    "createSchedule"

  @set
  external setDeleteSchedule: (component, Pulumi.Output.t<ReventlessSpec.Schedule.delete>) => unit =
    "deleteSchedule"
  @get
  external deleteSchedule: component => Pulumi.Output.t<ReventlessSpec.Schedule.delete> =
    "deleteSchedule"

  let findSideEffect = (sideEffects, event'Json) =>
    event'Json
    ->Js.Json.decodeObject
    ->Belt.Option.flatMapU(eventObj' => {
      let meta = eventObj'->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode)

      switch meta {
      | Some(Belt.Result.Ok(eventMeta)) =>
        let sideEffect =
          sideEffects->Belt.Array.getBy((module(SideEffect: ReventlessSpec.SideEffect.T)) =>
            SideEffect.Source.name == eventMeta.service
          )
        switch sideEffect {
        | None => None
        | Some(sideEffect) => Some((eventObj', eventMeta, sideEffect))
        }
      | Some(Error(err)) =>
        Js.log2("SideEffects.map: Couldn't decode meta:", err)
        None
      | _ =>
        Js.log("SideEffects.map: Invalid JSON object")
        None
      }
    })

  let eventsHandler = (sideEffects, queryEngine, events'Json) => {
    events'Json
    ->Belt.Array.map(async event'Json =>
      switch sideEffects->findSideEffect(event'Json) {
      | Some((eventObj, eventMeta, sideEffect)) =>
        module SideEffect = unpack(sideEffect)
        let sourceName = SideEffect.Source.name
        event'Json->Logger.logEvent'Json(
          `SideEffectHandler.eventsHandler: handling event from source ${sourceName}:`,
        )
        let idDecoded = eventObj->Js.Dict.get("id")->Belt.Option.map(SideEffect.Source.Id.t_decode)
        let eventDecoded =
          eventObj->Js.Dict.get("event")->Belt.Option.map(SideEffect.Source.event_decode)

        switch (idDecoded, eventDecoded) {
        | (Some(Ok(eventId)), Some(Ok(event))) =>
          try await SideEffect.execute(eventId, eventMeta, event, queryEngine) catch {
          | err => Js.log2("SideEffect: Error while processing:", err)
          }

        | (None, _)
        | (_, None) =>
          Js.log("SideEffectHandler.eventHandler: Invalid event")
        | (_, Some(Error(err)))
        | (Some(Error(err)), _) =>
          Js.log2("SideEffectHandler.eventHandler: Couldn't decode event:", err)
        }
      | None => ()
      }
    )
    ->Js.Promise.all
    ->Util.Promise.toUnit
  }

  let createScheduleFn = (scheduler, queueResources) =>
    async schedule => await Schedule.create(scheduler, queueResources)(schedule)

  let deleteScheduleFn = (scheduler, queueResources) =>
    async scheduleName => await Schedule.delete(scheduler, queueResources)(scheduleName)

  let enqueueEventFn = eventCollector =>
    EventCollector.enqueueEvent(eventCollector)->Pulumi.Output.apply(enqueueEvent =>
      async (delay, id, message) => await enqueueEvent(delay, id, message)
    )

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

    let eventsHandler = eventsHandler(sideEffects, queryEngine, ...)
    let eventCollector = EventCollector.make(
      ~name,
      ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
      ~eventsHandler,
      ~memorySize,
      ~timeout,
      ~policy1,
      ~policy2,
      ~opts=Some(opts),
    )
    let eventCollectorResources =
      (eventCollector->Component.extractOutputs).resources->Adapter.resourcesToUnwrappedOutput

    self->setEnqueueEvent(enqueueEventFn(eventCollector))
    self->setCreateSchedule(
      eventCollectorResources->Pulumi.Output.apply(eventCollectorResources =>
        createScheduleFn(scheduler, eventCollectorResources)
      ),
    )
    self->setDeleteSchedule(
      eventCollectorResources->Pulumi.Output.apply(eventCollectorResources =>
        deleteScheduleFn(scheduler, eventCollectorResources)
      ),
    )

    self->setOutputs({name, eventCollector: eventCollector->Component.extractOutputs})
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
    make(
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
