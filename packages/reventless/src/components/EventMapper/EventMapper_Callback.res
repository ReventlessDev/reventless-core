module type CounterOps = {
  let publishJsons: CommandTopic.publishJsons
  let queryEngine: ReventlessSpec.QueryEngine.operations
}

module type CounterHandler = {
  let commonEventsHandler: array<Js.Json.t> => promise<(
    promise<array<Reventless.Message.commandJson>>,
    array<Reventless.Counter.action>,
  )>
  let handleCounterEvents: EventCollector.jsonEventsHandler
}

module MakeCounterHandler = (
  Target: ReventlessSpec.EventMapping.Target,
  Mappings: EventMapper.Mappings with module Target := Target,
  Ops: CounterOps,
): CounterHandler => {
  let target = Target.name

  let findMapping = (mappings, eventJson') => {
    eventJson'
    ->Js.Json.decodeObject
    ->Option.flatMap(eventObj' => {
      switch eventObj'
      ->Js.Dict.get("meta")
      ->Option.map(metaJson => metaJson->Message.decode(Message.metaSchema)) {
      | Some(eventMeta) =>
        let source = eventMeta.service
        let mapping =
          mappings->Array.find((module(Mapping: Mappings.Mapping)) => Mapping.Source.name == source)
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
      | None =>
        Js.log2("EventMapper_Callback.findMapping: Invalid JSON object:", eventJson')
        None
      | exception err =>
        Js.log2("EventMapper_Callback.findMapping: Couldn't decode meta:", err)
        None
      }
    })
  }

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
    commandJson: command->Message.encode(Target.commandSchema),
    ?delay,
  }

  let processMappingActions = (actions, eventMeta) =>
    actions->Array.map(action =>
      switch action {
      | ReventlessSpec.EventMapping.Publish(id, command) =>
        Publisher([createCommandJson(id, eventMeta, command)]->Js.Promise.resolve)
      | PublishDelayed(id, command, delay) =>
        Publisher([createCommandJson(~delay, id, eventMeta, command)]->Js.Promise.resolve)
      | PublishAsync(promise) =>
        let toCommandJson = async promise =>
          {await promise}->Array.map(((id, command)) => createCommandJson(id, eventMeta, command))
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

  let commonEventsHandler = async eventsJson' => {
    let eventsCount = eventsJson'->Array.length
    let (publisherActions, counterActions) =
      eventsJson'
      ->Array.mapWithIndex((eventJson', idx) => {
        let idx = idx + 1
        eventJson'->Logger.logJsonEvent(
          `EventMapper.eventsHandler: incoming event ${idx->Int.toString}/${eventsCount->Int.toString}:`,
        )
        switch findMapping(Mappings.mappings, eventJson') {
        // TODO: support multiple mappings for the same source
        | Some((eventObj, eventMeta, mapping)) =>
          module Mapping = unpack(mapping)
          try {
            let idDecoded =
              eventObj
              ->Js.Dict.get("id")
              ->Option.map(id => id->Message.decode(Mapping.Source.Id.schema))
            let eventDecoded =
              eventObj
              ->Js.Dict.get("event")
              ->Option.map(event => event->Message.decode(Mapping.Source.eventSchema))

            switch (idDecoded, eventDecoded) {
            | (Some(eventId), Some(event)) =>
              Mapping.map(eventId, event, Ops.queryEngine)->processMappingActions(eventMeta)->Some
            | _ =>
              Js.log2("EventMapper.map: Invalid event:", eventJson')
              None
            }
          } catch {
          | err =>
            Js.log3("EventMapper.map: Couldn't decode event:", eventJson', err)
            None
          }
        | None => None
        }
      })
      ->Array.filterMap(entry => entry)
      ->Array.flat
      ->Belt.Array.partition(resultType =>
        switch resultType {
        | Publisher(_) => true
        | Counter(_) => false
        }
      )
    let publisherEntries =
      (await publisherActions
      ->Array.map(action =>
        switch action {
        | Publisher(entries) => entries
        | Counter(_) => Js.Exn.raiseError("Invalid EventMapper action")
        }
      )
      ->Js.Promise.all)
      ->Array.flat
      ->Js.Promise.resolve
    let counterActions = counterActions->Array.map(x =>
      switch x {
      | Counter(action) => action
      | Publisher(_) => Js.Exn.raiseError("Invalid EventMapper action")
      }
    )
    (publisherEntries, counterActions)
  }

  let handleCounterEvents = async eventsJson' => {
    let (publisherEntries, countActions) = await commonEventsHandler(eventsJson')
    if countActions->Array.length > 0 {
      Js.log("EventMapper.handleCounterEvents: Counter actions are not allowed in Count mapping!")
    }
    await Ops.publishJsons(await publisherEntries)
  }
}

module type EventCollectorOps = {
  let publishJsons: CommandTopic.publishJsons
  let count: Counter.count
  let addToCounterTarget: Counter.addToCounterTarget
  let commonEventsHandler: array<Js.Json.t> => promise<(
    promise<array<Reventless.Message.commandJson>>,
    array<Reventless.Counter.action>,
  )>
}

module type EventCollectorHandler = {
  let handleJsonEvents: EventCollector.jsonEventsHandler
}

module MakeEventCollectorHandler = (Ops: EventCollectorOps): EventCollectorHandler => {
  let rec doCount = async countItems =>
    switch countItems->Array.length {
    | 0 => ()
    | _ =>
      switch await Ops.count(countItems) {
      | exception e =>
        Js.log2(__MODULE__ ++ ".doCount: count error", e)
        let timeout = Js.Math.random_int(1000, 3000)
        await Reventless.Util.Promise.finishTimeout(timeout)
        Js.log(`Retry count after ${timeout->Js.Int.toString} ms`)
        await doCount(countItems)
      | _ => ()
      }
    }

  let handleJsonEvents = async eventsJson' => {
    let (publisherEntries, counterActions) = await Ops.commonEventsHandler(eventsJson')
    let (countActions, addToCounterTargetActions) = counterActions->Belt.Array.partition(x =>
      switch x {
      | Counter.Count(_) => true
      | AddToCounterTarget(_) => false
      }
    )

    let countItems = countActions->Array.filterMap(countAction =>
      switch countAction {
      | Count(countItem) => Some(countItem)
      | _ => None
      }
    )
    Js.log2("EventMapper.eventCollectorEventsHandler: countItems:", countItems->Array.length)
    await doCount(countItems)

    Js.log2(
      "EventMapper.eventCollectorEventsHandler: addToCounterTargetActions:",
      addToCounterTargetActions->Js.Json.stringifyAny,
    )
    await addToCounterTargetActions
    ->Array.map(async x =>
      switch x {
      | AddToCounterTarget(counterTarget) => await Ops.addToCounterTarget(counterTarget)
      | _ => ()
      }
    )
    ->Js.Promise.all
    ->Util.Promise.toUnit

    await Ops.publishJsons(await publisherEntries)
  }
}
