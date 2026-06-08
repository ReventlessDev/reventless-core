module type CounterOps = {
  let publishJsons: CommandTopic.publishJsons
  let queryEngine: Reventless.QueryEngine.operations
}

module type CounterHandler = {
  let commonEventsHandler: array<JSON.t> => promise<(
    promise<array<Message.commandJson>>,
    array<Counter.action>,
  )>
  let handleCounterEvents: Counter.jsonEventsHandler
}

module MakeCounterHandler = (
  Target: Reventless.EventMapping.Target,
  Mappings: EventMapper.Mappings with module Target := Target,
  Ops: CounterOps,
): CounterHandler => {
  let target = Target.name

  // Pair each mapping with the variant TAGs it declares via Source.eventSchema.
  // Used to pre-filter incoming envelopes by TAG before attempting decode —
  // sibling variants on the same source aggregate that this mapping does not
  // declare are silently skipped instead of producing decode-failure noise.
  let mappingsWithTags = Mappings.mappings->Array.map((module(M: Mappings.Mapping)) => (
    module(M: Mappings.Mapping),
    Reventless.DcbTag.extractAllVariantNames(M.Source.eventSchema),
  ))

  // Looks up the event mapping for a given event JSON by matching the source service name
  // from the event's meta against the registered Mapping modules.
  let findMapping = (mappingsWithTags, eventJson') => {
    eventJson'
    ->JSON.Decode.object
    ->Option.flatMap(eventObj' => {
      switch eventObj'
      ->Dict.get("meta")
      ->Option.map(metaJson => metaJson->Message.decode(Message.metaSchema)) {
      | Some(eventMeta) =>
        let source = eventMeta.service
        let entry =
          mappingsWithTags->Array.find(((module(Mapping: Mappings.Mapping), _)) =>
            Mapping.Source.name == source
          )
        switch entry {
        | None =>
          EffectLogger.logInfo(~comp="EventMapper", `map: No mapping ${source} -> ${target} found`)->Effect.runSync
          None
        | Some((mapping, acceptedTags)) =>
          module Mapping = unpack(mapping)
          let source = Mapping.Source.name
          EffectLogger.logInfo(~comp="EventMapper", `map: found mapping ${source} -> ${target}`)->Effect.runSync
          Some((eventObj', eventMeta, mapping, acceptedTags))
        }
      | None =>
        EffectLogger.logError(
          ~comp="EventMapper",
          `findMapping: Invalid JSON object: ${eventJson'->JSON.stringify}`,
        )->Effect.runSync
        None
      | exception err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp="EventMapper",
          `findMapping: Couldn't decode meta: ${errMsg}`,
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
    // Derive a child meta from the source event:
    // - fresh msgId + time
    // - causationId = source event's msgId
    // - service overridden to the target's name (this command is being routed to Target)
    // - correlationId / ip / user / traceparent / schemaVersion / headers inherited
    meta: Message.deriveMeta(~parent=meta, ~service=Target.name),
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
  // For each event: finds the mapping, decodes id+event, runs Mapping.map (EventMapping), then splits
  // the resulting actions into (publisherEntries, counterActions).
  let commonEventsHandler = async eventsJson' => {
    let eventsCount = eventsJson'->Array.length
    let (publisherActions, counterActions) =
      eventsJson'
      ->Array.mapWithIndex((eventJson', idx) => {
        let idx = idx + 1
        EffectLogger.logInfo(
          ~comp="EventMapper",
          `eventsHandler: incoming event ${idx->Int.toString}/${eventsCount->Int.toString}: ${LogFormat.event'JsonToLogMessage(
              eventJson',
            )}`,
        )->Effect.runSync
        switch findMapping(mappingsWithTags, eventJson') {
        // TODO: support multiple mappings for the same source
        | Some((eventObj, eventMeta, mapping, acceptedTags)) =>
          module Mapping = unpack(mapping)
          // Pre-filter by TAG: sibling variants from the same source aggregate
          // that this mapping does not declare are not its concern — skip
          // silently with no decode attempt. Real decode failures on declared
          // variants still throw and are logged below.
          let tag =
            eventObj
            ->Dict.get("event")
            ->Option.map(Message.variantNameOfJson)
            ->Option.getOr("unknown")
          if !(acceptedTags->Array.includes(tag)) {
            None
          } else {
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
                EffectLogger.logError(
                  ~comp="EventMapper",
                  `map: Invalid event: ${eventJson'->JSON.stringify}`,
                )->Effect.runSync
                None
              }
            } catch {
            | err =>
              let errMsg =
                err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
              EffectLogger.logError(
                ~comp="EventMapper",
                `map: Couldn't decode event: ${eventJson'->JSON.stringify} ${errMsg}`,
              )->Effect.runSync
              None
            }
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
          EffectLogger.logError(
            ~comp="EventMapper",
            "handleCounterEvents: Counter actions are not allowed in Count mapping!",
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
    promise<array<Message.commandJson>>,
    array<Counter.action>,
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
        EffectLogger.logError(~comp=__MODULE__, `doCount: count error after retries: ${errMsg}`)
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
        EffectLogger.logInfo(
          ~comp="EventMapper",
          `eventCollectorEventsHandler: countItems: ${countItems
            ->Array.length
            ->Int.toString}`,
        )
        ->Effect.flatMap(_ => doCount(countItems))
        ->Effect.flatMap(_ =>
          EffectLogger.logInfo(
            ~comp="EventMapper",
            `eventCollectorEventsHandler: addToCounterTargetActions: ${addToCounterTargetActions
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
