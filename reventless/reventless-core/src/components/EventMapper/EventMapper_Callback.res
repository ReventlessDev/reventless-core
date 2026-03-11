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

  // Looks up the event mapping for a given event JSON by matching the source service name
  // from the event's meta against the registered Mapping modules.
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

  // Converts high-level EventMapping actions into concrete Publisher/Counter actions,
  // stamping each with the event's meta (service name, correlation ID, timestamps).
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

  // Shared event processing logic used by both Counter and EventCollector handlers.
  // For each event: finds the mapping, decodes id+event, runs Mapping.map, then splits
  // the resulting actions into (publisherEntries, counterActions).
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
      ->Array.partition(resultType =>
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

  // Counter stream handler — maps events via commonEventsHandler, rejects counter actions
  // (counter-to-counter mapping is not allowed), and publishes generated commands.
  let handleCounterEvents: Counter.jsonEventsHandler = stream =>
    stream->Stream.runForEach(eventJson' =>
      Effect.promise(() => commonEventsHandler([eventJson']))
      ->Effect.tap(((_, countActions)) =>
        if countActions->Array.length > 0 {
          Effect.logError(
            "EventMapper.handleCounterEvents: Counter actions are not allowed in Count mapping!",
          )
        } else {
          Effect.succeed()
        }
      )
      ->Effect.flatMap(((publisherEntries, _)) =>
        Effect.promise(() => publisherEntries)
        ->Effect.flatMap(entries => Effect.promise(() => Ops.publishJsons(entries)))
      )
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
  let countRetrySchedule =
    Schedule.exponential(Duration.millis(1000))
    ->Schedule.jittered
    ->Schedule.intersect(Schedule.recurs(10))

  // Applies counter increments to the QueryDb with retry on failure.
  let doCount = countItems =>
    switch countItems->Array.length {
    | 0 => Effect.succeed()
    | _ =>
      Effect.tryPromise(
        ~catch=e => Util.Error.messageFromUnknown(e, "unknown"),
        () => Ops.count(countItems),
      )
      ->Effect.retry(countRetrySchedule)
      ->Effect.catchAll(errMsg =>
        Effect.logError(__MODULE__ ++ `.doCount: count error after retries: ${errMsg}`)
      )
    }

  // EventCollector stream handler — maps events via commonEventsHandler, then:
  //   1. Applies counter increments (with retry)
  //   2. Registers counter targets
  //   3. Publishes generated commands to the target aggregate
  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream->Stream.runForEach(eventJson' =>
      Effect.promise(() => Ops.commonEventsHandler([eventJson']))
      ->Effect.flatMap(((publisherEntries, counterActions)) => {
        let (countActions, addToCounterTargetActions) = counterActions->Array.partition(
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
        )
        ->Effect.flatMap(_ => doCount(countItems))
        ->Effect.flatMap(_ =>
          Effect.logInfo(
            `EventMapper.eventCollectorEventsHandler: addToCounterTargetActions: ${addToCounterTargetActions
              ->JSON.stringifyAny
              ->Option.getOr("[]")}`,
          )
        )
        ->Effect.flatMap(_ =>
          Effect.all(
            addToCounterTargetActions->Array.filterMap(x =>
              switch x {
              | AddToCounterTarget(counterTarget) =>
                Some(Effect.promise(() => Ops.addToCounterTarget(counterTarget)))
              | _ => None
              }
            ),
            {"concurrency": "unbounded"},
          )->Effect.map(_ => ())
        )
        ->Effect.flatMap(_ =>
          Effect.promise(() => publisherEntries)
          ->Effect.flatMap(entries => Effect.promise(() => Ops.publishJsons(entries)))
        )
      })
    )
}
