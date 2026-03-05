module type CounterOps = {
  let publishJsons: CommandTopic.publishJsons
  let queryEngine: Reventless.QueryEngine.operations
}

module type CounterHandler = {
  let commonEventsHandler: array<JSON.t> => promise<(
    promise<array<ReventlessCore.Message.commandJson>>,
    array<ReventlessCore.Counter.action>,
  )>
  let handleCounterEvents: Counter.jsonEventsHandler
}

module MakeCounterHandler = (
  Target: Reventless.EventMapping.Target,
  Mappings: EventMapper.Mappings with module Target := Target,
  Ops: CounterOps,
): CounterHandler => {
  let target = Target.name

  let findMapping = (mappings, eventJson') => {
    eventJson'
    ->JSON.Decode.object
    ->Option.flatMap(eventObj' => {
      switch eventObj'
      ->Dict.get("meta")
      ->Option.map(metaJson => metaJson->Message.decode(Message.metaSchema)) {
      | Some(eventMeta) =>
        let source = eventMeta.service
        let mapping =
          mappings->Array.find((module(Mapping: Mappings.Mapping)) => Mapping.Source.name == source)
        switch mapping {
        | None =>
          Effect.logInfo(`EventMapper.map: No mapping ${source} -> ${target} found`)->Effect.runSync
          None
        | Some(mapping) =>
          module Mapping = unpack(mapping)
          let source = Mapping.Source.name
          Effect.logInfo(`EventMapper.map: found mapping ${source} -> ${target}`)->Effect.runSync
          Some((eventObj', eventMeta, mapping))
        }
      | None =>
        Effect.logError(
          `EventMapper_Callback.findMapping: Invalid JSON object: ${eventJson'->JSON.stringify}`,
        )->Effect.runSync
        None
      | exception err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `EventMapper_Callback.findMapping: Couldn't decode meta: ${errMsg}`,
        )->Effect.runSync
        None
      }
    })
  }

  type action =
    | Counter(Counter.action)
    | Publisher(promise<array<Message.commandJson>>)

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
      | Reventless.EventMapping.Publish(id, command) =>
        Publisher([createCommandJson(id, eventMeta, command)]->Promise.resolve)
      | PublishDelayed(id, command, delay) =>
        Publisher([createCommandJson(~delay, id, eventMeta, command)]->Promise.resolve)
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
        Effect.logInfo(
          `EventMapper.eventsHandler: incoming event ${idx->Int.toString}/${eventsCount->Int.toString}: ${LogFormat.event'JsonToLogMessage(
              eventJson',
            )}`,
        )->Effect.runSync
        switch findMapping(Mappings.mappings, eventJson') {
        // TODO: support multiple mappings for the same source
        | Some((eventObj, eventMeta, mapping)) =>
          module Mapping = unpack(mapping)
          try {
            let idDecoded =
              eventObj
              ->Dict.get("id")
              ->Option.map(id => id->Message.decode(Mapping.Source.Id.schema))
            let eventDecoded =
              eventObj
              ->Dict.get("event")
              ->Option.map(event => event->Message.decode(Mapping.Source.eventSchema))

            switch (idDecoded, eventDecoded) {
            | (Some(eventId), Some(event)) =>
              Mapping.map(eventId, event, Ops.queryEngine)->processMappingActions(eventMeta)->Some
            | _ =>
              Effect.logError(
                `EventMapper.map: Invalid event: ${eventJson'->JSON.stringify}`,
              )->Effect.runSync
              None
            }
          } catch {
          | err =>
            let errMsg =
              err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
            Effect.logError(
              `EventMapper.map: Couldn't decode event: ${eventJson'->JSON.stringify} ${errMsg}`,
            )->Effect.runSync
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
      (
        await publisherActions
        ->Array.map(action =>
          switch action {
          | Publisher(entries) => entries
          | Counter(_) => JsError.throwWithMessage("Invalid EventMapper action")
          }
        )
        ->Promise.all
      )
      ->Array.flat
      ->Promise.resolve
    let counterActions = counterActions->Array.map(x =>
      switch x {
      | Counter(action) => action
      | Publisher(_) => JsError.throwWithMessage("Invalid EventMapper action")
      }
    )
    (publisherEntries, counterActions)
  }

  let handleCounterEvents: Counter.jsonEventsHandler = stream =>
    stream->Stream.runForEach(eventJson' =>
      Effect.promise(async () => {
        let (publisherEntries, countActions) = await commonEventsHandler([eventJson'])
        if countActions->Array.length > 0 {
          Effect.logError(
            "EventMapper.handleCounterEvents: Counter actions are not allowed in Count mapping!",
          )->Effect.runSync
        }
        await Ops.publishJsons(await publisherEntries)
      })
    )
}

module type EventCollectorOps = {
  let publishJsons: CommandTopic.publishJsons
  let count: Counter.count
  let addToCounterTarget: Counter.addToCounterTarget
  let commonEventsHandler: array<JSON.t> => promise<(
    promise<array<ReventlessCore.Message.commandJson>>,
    array<ReventlessCore.Counter.action>,
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
        let errMsg = e->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(__MODULE__ ++ `.doCount: count error: ${errMsg}`)->Effect.runSync
        let timeout = Math.Int.random(1000, 3000)
        await ReventlessCore.Util.Promise.finishTimeout(timeout)
        Effect.logInfo(`Retry count after ${timeout->Int.toString} ms`)->Effect.runSync
        await doCount(countItems)
      | _ => ()
      }
    }

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream->Stream.runForEach(eventJson' =>
      Effect.promise(async () => {
        let (publisherEntries, counterActions) = await Ops.commonEventsHandler([eventJson'])
        let (countActions, addToCounterTargetActions) = counterActions->Belt.Array.partition(
          x =>
            switch x {
            | Counter.Count(_) => true
            | AddToCounterTarget(_) => false
            },
        )

        let countItems = countActions->Array.filterMap(
          countAction =>
            switch countAction {
            | Count(countItem) => Some(countItem)
            | _ => None
            },
        )
        Effect.logInfo(
          `EventMapper.eventCollectorEventsHandler: countItems: ${countItems
            ->Array.length
            ->Int.toString}`,
        )->Effect.runSync
        await doCount(countItems)

        Effect.logInfo(
          `EventMapper.eventCollectorEventsHandler: addToCounterTargetActions: ${addToCounterTargetActions
            ->JSON.stringifyAny
            ->Option.getOr("[]")}`,
        )->Effect.runSync
        await addToCounterTargetActions
        ->Array.map(
          async x =>
            switch x {
            | AddToCounterTarget(counterTarget) => await Ops.addToCounterTarget(counterTarget)
            | _ => ()
            },
        )
        ->Promise.all
        ->Util.Promise.toUnit

        await Ops.publishJsons(await publisherEntries)
      })
    )
}
