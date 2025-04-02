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

  let findMapping = (mappings, eventObj) =>
    eventObj->Belt.Option.flatMapU(eventObj' => {
      let meta = eventObj'->Js.Dict.get("meta")->Belt.Option.map(Message.meta_decode)

      switch meta {
      | Some(Belt.Result.Ok(eventMeta)) =>
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

  let commonEventsHandler = async eventsJson => {
    let eventsCount = eventsJson->Belt.Array.size
    let (publisherActions, counterActions) =
      eventsJson
      ->Array.mapWithIndex((eventJson, idx) => {
        let idx = idx + 1
        eventJson->Logger.logJsonEvent(
          `EventMapper.eventsHandler: incoming event ${idx->Belt.Int.toString}/${eventsCount->Belt.Int.toString}:`,
        )
        let event' = eventJson->Js.Json.decodeObject
        switch findMapping(Mappings.mappings, event') {
        // TODO: support multiple mappings for the same source
        | Some((eventObj, eventMeta, mapping)) =>
          module Mapping = unpack(mapping)
          let idDecoded = eventObj->Js.Dict.get("id")->Belt.Option.map(Mapping.Source.Id.t_decode)
          let eventDecoded =
            eventObj->Js.Dict.get("event")->Belt.Option.map(Mapping.Source.event_decode)

          switch (idDecoded, eventDecoded) {
          | (Some(Ok(eventId)), Some(Ok(event))) =>
            Mapping.map(eventId, event, Ops.queryEngine)->processMappingActions(eventMeta)->Some
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
    if countActions->Belt.Array.size > 0 {
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
    switch countItems->Belt.Array.size {
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

    let countItems = countActions->Belt.Array.keepMap(countAction =>
      switch countAction {
      | Count(countItem) => Some(countItem)
      | _ => None
      }
    )
    Js.log2("EventMapper.eventCollectorEventsHandler: countItems:", countItems->Belt.Array.size)
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
