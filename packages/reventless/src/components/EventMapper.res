module ReventlessEventCollector = EventCollector

let componentType = ComponentType.EventMapper

type outputs = {
  name: string,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  counter?: Counter.outputs,
}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~allEventTopics: EventTopic.allOutputs,
    ~queryEngine: ReventlessSpec.QueryEngine.operations,
    ~publishJsons: CommandTopic.publishJsons,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

module type Mappings = {
  module Target: ReventlessSpec.EventMapping.Target
  module type Mapping = ReventlessSpec.EventMapping.T with module Target := Target
  let mappings: array<module(Mapping)>
  let counter: option<module(Counter.T)>
}

module Make = (
  Target: ReventlessSpec.EventMapping.Target,
  EventCollector: EventCollector.T,
  Mappings: Mappings with module Target := Target,
): T => {
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

  module Target = Target
  let target = Target.name

  let findMapping = (mappings, eventObj) =>
    eventObj->Belt.Option.flatMapU(eventObj' => {
      let meta = eventObj'->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode)

      switch meta {
      | Some(Belt.Result.Ok(eventMeta)) =>
        let source = eventMeta.service
        let mapping =
          mappings->Belt.Array.getBy((module(Mapping: Mappings.Mapping)) =>
            Mapping.Source.name == source
          )
        switch mapping {
        | None =>
          Js.log(`EventMapper.map: No mapping ${source} -> ${target} found`)
          None
        | Some(mapping) =>
          module Mapping = unpack(mapping)
          let source = Mapping.Source.name
          Js.log(`EventMapper.map: found mapping ${source} -> ${target}`)
          Some((eventObj', eventMeta, mapping))
        }
      | Some(Error(err)) =>
        Js.log2("EventMapper.map: Couldn't decode meta:", err)
        None
      | _ =>
        Js.log("EventMapper.map: Invalid JSON object")
        None
      }
    })

  type action =
    | Counter(Counter.action)
    | Publisher(Js.Promise.t<array<Message.commandJson>>)

  let createCommandJson = (~delay=?, id, meta, command) => {
    Message.id: id->Target.Id.toString,
    meta: {
      ...meta,
      service: Target.name,
      msgId: Message.uuid(),
      time: Message.nowAsISOString(),
    },
    commandJson: command->Target.command_encode,
    delay,
  }

  let processMappingActions = (actions, eventMeta) =>
    actions->Belt.Array.map(action =>
      switch action {
      | ReventlessSpec.EventMapping.Publish(id, command) =>
        Publisher([createCommandJson(id, eventMeta, command)]->Js.Promise.resolve)
      | PublishDelayed(id, command, delay) =>
        Publisher([createCommandJson(~delay, id, eventMeta, command)]->Js.Promise.resolve)
      | PublishAsync(promise) =>
        let toCommandJson = async promise =>
          {await promise}->Belt.Array.map(((id, command)) =>
            createCommandJson(id, eventMeta, command)
          )
        Publisher(promise->toCommandJson)
      | AddToCounterTarget({counterId, target}) =>
        Counter(
          AddToCounterTarget({
            counterId,
            target,
            targetRef: eventMeta.correlationId,
          }),
        )
      | Count(counterId) => Counter(Count({counterId, reference: eventMeta.correlationId, inc: 1}))
      | CountMulti(counterId, inc) =>
        Counter(Count({counterId, reference: eventMeta.correlationId, inc}))
      }
    )

  let commonEventsHandler = async (mappings, queryEngine, events'Json) => {
    let eventsCount = events'Json->Belt.Array.size
    let (publisherActions, counterActions) =
      events'Json
      ->Belt.Array.mapWithIndex((idx, event'Json) => {
        let idx = idx + 1
        event'Json->Logger.logEvent'Json(
          `EventMapper.eventsHandler: incoming event ${idx->Belt.Int.toString}/${eventsCount->Belt.Int.toString}:`,
        )
        let event' = event'Json->Js.Json.decodeObject
        switch findMapping(mappings, event') {
        // TODO: support multiple mappings for the same source
        | Some((eventObj, eventMeta, mapping)) =>
          module Mapping = unpack(mapping)
          let idDecoded = eventObj->Js.Dict.get("id")->Belt.Option.map(Mapping.Source.Id.t_decode)
          let eventDecoded =
            eventObj->Js.Dict.get("event")->Belt.Option.map(Mapping.Source.event_decode)

          switch (idDecoded, eventDecoded) {
          | (Some(Ok(eventId)), Some(Ok(event))) =>
            Mapping.map(eventId, event, queryEngine)->processMappingActions(eventMeta)->Some
          | (None, _)
          | (_, None) =>
            Js.log("EventMapper.map: Invalid event")
            None
          | (_, Some(Error(err)))
          | (Some(Error(err)), _) =>
            Js.log2("EventMapper.map: Couldn't decode event:", err)
            None
          }
        | None => None
        }
      })
      ->Belt.Array.keepMap(entry => entry)
      ->Belt.Array.concatMany
      ->Belt.Array.partition(resultType =>
        switch resultType {
        | Publisher(_) => true
        | Counter(_) => false
        }
      )
    let publisherEntries =
      (await publisherActions
      ->Belt.Array.map(action =>
        switch action {
        | Publisher(entries) => entries
        | Counter(_) => Js.Exn.raiseError("Invalid EventMapper action")
        }
      )
      ->Js.Promise.all)
      ->Belt.Array.concatMany
      ->Js.Promise.resolve
    let counterActions = counterActions->Belt.Array.map(x =>
      switch x {
      | Counter(action) => action
      | Publisher(_) => Js.Exn.raiseError("Invalid EventMapper action")
      }
    )
    (publisherEntries, counterActions)
  }

  let rec doCount = async (count, countActions) =>
    switch countActions->Belt.Array.size {
    | 0 => ()
    | _ =>
      switch await count(countActions) {
      | exception e =>
        Js.log2(__MODULE__ ++ ".doCount: count error", e)
        let timeout = Js.Math.random_int(1000, 3000)
        await Reventless.Util.Promise.finishTimeout(timeout)
        Js.log(`Retry count after ${timeout->Js.Int.toString} ms`)
        await doCount(count, countActions)
      | _ => ()
      }
    }

  let eventCollectorEventsHandler = (
    publishJsons,
    mappings,
    queryEngine,
    count: Counter.count,
    addToCounterTarget: Counter.addToCounterTarget,
  ) =>
    async events'Json => {
      let (publisherEntries, counterActions) = await commonEventsHandler(
        mappings,
        queryEngine,
        events'Json,
      )
      let (countActions, addToCounterTargetActions) = counterActions->Belt.Array.partition(x =>
        switch x {
        | Counter.Count(_) => true
        | AddToCounterTarget(_) => false
        }
      )

      let countActions = countActions->Belt.Array.keepMap(countAction =>
        switch countAction {
        | Count(countItem) => Some(countItem)
        | _ => None
        }
      )
      Js.log2(
        "EventMapper.eventCollectorEventsHandler: countActions:",
        countActions->Belt.Array.size,
      )
      await doCount(count, countActions)

      Js.log2(
        "EventMapper.eventCollectorEventsHandler: addToCounterTargetActions:",
        addToCounterTargetActions->Js.Json.stringifyAny,
      )
      await addToCounterTargetActions
      ->Belt.Array.map(async x =>
        switch x {
        | AddToCounterTarget(counterTarget) => await addToCounterTarget(counterTarget)
        | _ => ()
        }
      )
      ->Js.Promise.all
      ->Util.Promise.toUnit

      await publishJsons(await publisherEntries)
    }

  let counterEventsHandler = (publishJsons, mappings, queryEngine) =>
    async events'Json => {
      let (publisherEntries, countActions) = await commonEventsHandler(
        mappings,
        queryEngine,
        events'Json,
      )
      if countActions->Belt.Array.size > 0 {
        Js.log(
          "EventMapper.counterEventsHandler: Counter actions are not allowed in Count mapping!",
        )
      }
      await publishJsons(await publisherEntries)
    }

  let construct = (
    ~allEventTopics,
    ~queryEngine,
    ~publishJsons,
    ~memorySize,
    ~timeout,
    self,
    name,
  ) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let (counterOperations, counterOutputs) = Mappings.counter->Belt.Option.mapWithDefault(
      (
        Pulumi.Output.make({
          Counter.count: async _items => Js.log("No counter deployed, but trying to use count"),
          addToCounterTarget: async _target =>
            Js.log("No counter deployed, but trying to use addToCounterTarget"),
        }),
        None,
      ),
      (module(Counter: Counter.T)) => {
        let counter = Counter.make(
          ~name,
          ~counterEventsHandler=counterEventsHandler(publishJsons, Mappings.mappings, queryEngine),
          ~opts,
        )
        (counter->Component.operations, counter->Component.extractOutputs->Some)
      },
    )

    module Set = Belt.Set.String
    let aggregateNames =
      Mappings.mappings
      ->Belt.Array.keepMap((module(Mapping: Mappings.Mapping)) =>
        if Mapping.Source.name != Counter.Source.name {
          Some(Mapping.Source.name)
        } else {
          None
        }
      )
      ->Set.fromArray

    let eventCollector =
      counterOperations->Pulumi.Output.apply(({count, addToCounterTarget}) =>
        EventCollector.make(
          ~name=Target.name->ComponentType.name(componentType),
          ~eventTopics=allEventTopics->Util.EventTopic.filterEventTopics(aggregateNames),
          ~eventsHandler=eventCollectorEventsHandler(
            publishJsons,
            Mappings.mappings,
            queryEngine,
            count,
            addToCounterTarget,
          ),
          ~memorySize,
          ~timeout,
          ~policy1=Pulumi.Output.make(None),
          ~policy2=Pulumi.Output.make(None),
          ~opts=Some(opts),
        )->Component.extractOutputs
      )

    self->setOutputs({
      name,
      eventCollector,
      counter: ?counterOutputs,
    })
  }

  let make = (
    ~allEventTopics,
    ~queryEngine,
    ~publishJsons,
    ~memorySize=2048,
    ~timeout=180,
    ~opts=?,
  ) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=Target.name,
      ~construct=construct(
        ~allEventTopics,
        ~queryEngine,
        ~publishJsons,
        ~memorySize,
        ~timeout,
        ...
      ),
      ~opts,
    )
}
