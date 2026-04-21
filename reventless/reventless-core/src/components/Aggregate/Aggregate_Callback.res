module type Ops = {
  module Spec: Reventless.Aggregate.Spec
  module EventLog: EventLog.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventLog: EventLog.operations
}

module type T = {
  module Spec: Reventless.Aggregate.Spec
  let handleCommands: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>
}

module Make = (
  Spec: Reventless.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
  Ops: Ops with module Spec = Spec,
): (T with module Spec = Spec) => {
  module Spec = Spec

  let comp = `Aggregate(${Spec.name})`

  let eventJson = (event': Message.event'<Spec.Id.t, Spec.event>): JSON.t =>
    event'.event->Message.encode(Spec.eventSchema)

  let eventDetail = (event': Message.event'<Spec.Id.t, Spec.event>): string => {
    let json = event'->eventJson
    let name = json->Message.variantNameOfJson->LogFormat.bold
    let id = event'.id->Spec.Id.toString
    `${name}(${id}${LogFormat.variantFields(json)})`
  }

  // Collects the incoming command stream into groups keyed by aggregate ID.
  // Returns Effect.t<array<(Id.t, array<topicItem>)>>.
  let groupTopicItemsByIdStream = stream =>
    stream
    ->Stream.runFold(Dict.make(), (
      dict,
      item: CommandTopic.topicItem<Message.command'<Spec.Id.t, Spec.command>>,
    ) => {
      let id = item.command.id->Spec.Id.toString
      let existing = dict->Dict.get(id)->Option.getOr([])
      dict->Dict.set(id, Array.concat(existing, [item]))
      dict
    })
    ->Effect.map(dict =>
      dict->Dict.toArray->Array.map(((id, items)) => (id->Spec.Id.makeFromString, items))
    )

  let updateMeta = (command': Message.command'<'id, 'command>) => {
    ...command'.meta,
    time: Message.nowAsISOString(),
    msgId: Message.uuid(),
  }

  // Folds a single command into the running accumulator: (currentState, collectedEvents).
  // Delegates to Behavior.decide and handles errors by logging and continuing.
  // Short-circuits on prior Error — subsequent commands in the batch are skipped.
  let processCommand = (acc, command': Message.command'<Spec.Id.t, Spec.command>) =>
    switch acc {
    | Ok((state, events)) =>
      let decide = () =>
        switch Behavior.decide(state, command'.command) {
        | Ok(generatedEvents) =>
          let newState = generatedEvents->Array.reduce(state, Behavior.evolve)
          Ok((newState, Array.concat(events, [(generatedEvents, command'->updateMeta)])))
        | Error(error) =>
          let errorJson = error->Message.encode(Spec.errorSchema)->JSON.stringify
          let id = command'.id->Spec.Id.toString
          EffectLogger.logError(~comp, `decide error: ${errorJson} id=${id}`)->Effect.runSync
          Ok((state, events))
        }
      Effect.succeed(decide())
    | Error(_) as error => Effect.succeed(error)
    }

  let maxConflictRetries = 3

  // Replays the event log, processes commands, and attempts to append.
  // Returns Ok(references) on success, Error("conflict") on optimistic locking failure,
  // or Error(references) on other append failures.
  let replayProcessAppend = (
    id,
    topicItemsForId: array<CommandTopic.topicItem<Message.command'<Spec.Id.t, Spec.command>>>,
  ) => {
    let (references, commands') =
      topicItemsForId
      ->Array.map(({reference, command}) => (reference, command))
      ->Array.unzip

    let idStr = id->Spec.Id.toString

    Ops.eventLog.replayStream(id)
    ->Stream.runFold((Behavior.initialState, 0), ((st, n), ev) => (Behavior.evolve(st, ev), n + 1))
    ->Effect.tap(((_, n)) =>
      EffectLogger.logInfo(~comp, `replay: id=${idStr}, ${n->Int.toString} event(s)`)
    )
    ->Effect.flatMap(((initialState, sequenceNr)) => {
      commands'
      ->Array.reduce(Effect.succeed(Ok((initialState, []))), (accEffect, command') =>
        accEffect->Effect.flatMap(acc => processCommand(acc, command'))
      )
      ->Effect.flatMap(result => {
        let events = switch result {
        | Ok((_, generatedEventsWithMeta)) =>
          generatedEventsWithMeta
          ->Array.map(((events, meta)) => events->Array.map(event => {Message.id, meta, event}))
          ->Array.flat
        | Error(error) => JsError.throwWithMessage(error)
        }
        switch events {
        | [] =>
          references->Array.forEach(reference =>
            CommandTopic_Helpers.reportAccepted(reference, {entityId: idStr, eventCount: 0})
          )
          EffectLogger.logInfo(~comp, `no events produced: id=${idStr}`)->Effect.map(
            _ => Ok(references->Array.map(reference => Ok(reference))),
          )
        | generatedEvents' =>
          let eventCount = generatedEvents'->Array.length->Int.toString
          let eventDetails =
            generatedEvents'->Array.map(event' => event'->eventDetail)->Array.join(", ")
          let eventJsons =
            generatedEvents'->Array.map(event' => event'->eventJson)->JSON.Encode.array
          EffectLogger.logInfo(
            ~comp,
            ~detail=eventJsons,
            `produced ${eventCount} event(s): [${eventDetails}]`,
          )
          ->Effect.flatMap(
            _ => Effect.promise(() => Ops.eventLog.append(sequenceNr, id, generatedEvents')),
          )
          ->Effect.flatMap(
            appendResult =>
              switch appendResult {
              | Ok(_) =>
                references->Array.forEach(reference =>
                  CommandTopic_Helpers.reportAccepted(reference, {
                    entityId: idStr,
                    eventCount: generatedEvents'->Array.length,
                  })
                )
                EffectLogger.logInfo(~comp, `append: id=${idStr}`)->Effect.map(
                  _ => Ok(references->Array.map(reference => Ok(reference))),
                )
              | Error(msg) if msg->String.includes("conflict") =>
                EffectLogger.logWarn(~comp, `conflict: id=${idStr}, will retry`)->Effect.map(
                  _ => Error("conflict"),
                )
              | Error(_) =>
                EffectLogger.logError(~comp, `append failed: id=${idStr}`)->Effect.map(
                  _ => Ok(references->Array.map(reference => Error(reference))),
                )
              },
          )
        }
      })
    })
  }

  // CommandTopic handler — processes a stream of incoming commands:
  //   1. Groups commands by aggregate ID
  //   2. For each aggregate (concurrently):
  //      a. Replays the event log to rebuild current state + sequence number
  //      b. Sequentially folds each command through processCommand
  //      c. Appends generated events to the event log (optimistic concurrency via sequenceNr)
  //      d. On conflict: retries the full replay+process+append cycle (up to 3 times)
  //   3. Returns Ok(reference) for successful commands, Error(reference) for failures
  let handleCommands: CommandTopic.commandsHandler<
    Message.command'<Spec.Id.t, Spec.command>,
  > = stream =>
    stream
    ->groupTopicItemsByIdStream
    ->Effect.flatMap(groups =>
      Effect.all(
        groups->Array.map(((id, topicItemsForId)) => {
          let idStr = id->Spec.Id.toString
          // Log commands once (outside retry loop)
          let cmdJsons =
            topicItemsForId->Array.map(
              ({command}) =>
                command->Message.commandJsonOfCommand'(
                  ~idToString=Spec.Id.toString,
                  ~commandSchema=Spec.commandSchema,
                ),
            )
          let count = cmdJsons->Array.length->Int.toString
          cmdJsons->Array.forEachWithIndex(
            (cmdJson, idx) => {
              let idxStr = (idx + 1)->Int.toString
              EffectLogger.logInfo(
                ~comp,
                ~detail=cmdJson.commandJson,
                `handling command ${idxStr}/${count}: ${LogFormat.cmdDetail(cmdJson)}`,
              )->Effect.runSync
            },
          )

          // Extract references once for the exhaustion branch
          let references = topicItemsForId->Array.map(item => item.reference)

          // Retry loop for conflict resolution
          let rec attempt = retryCount =>
            replayProcessAppend(id, topicItemsForId)->Effect.flatMap(
              result =>
                switch result {
                | Ok(refs) => Effect.succeed(refs)
                | Error(_) if retryCount < maxConflictRetries =>
                  EffectLogger.logWarn(
                    ~comp,
                    `conflict retry id=${idStr} ${(retryCount + 1)
                        ->Int.toString}/${maxConflictRetries->Int.toString}`,
                  )->Effect.flatMap(_ => attempt(retryCount + 1))
                | Error(_) =>
                  EffectLogger.logError(
                    ~comp,
                    `max conflict retries exhausted id=${idStr}`,
                  )->Effect.map(_ => references->Array.map(reference => Error(reference)))
                },
            )
          attempt(0)
        }),
        {"concurrency": "unbounded"},
      )->Effect.map(Array.flat)
    )
}
