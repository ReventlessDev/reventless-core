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

  // Per-command outcome carried through the fold, paired with the originating reference and meta.
  type cmdOutcome =
    | CmdOk(array<Spec.event>)
    | CmdRejected({errorCode: string, errorDetail: string})

  // Folds a single command into the running accumulator: (currentState, perCommandOutcomes).
  // A domain rejection from Behavior.decide is recorded as `CmdRejected` (no state change,
  // surviving commands in the batch continue); a successful decide records `CmdOk(events)`
  // and advances state via `Behavior.evolve`.
  let processCommand = (
    (state, outcomes): (Behavior.state, array<(string, cmdOutcome, Message.meta)>),
    topicItem: CommandTopic.topicItem<Message.command'<Spec.Id.t, Spec.command>>,
  ) => {
    let {reference, command: command'} = topicItem
    let meta = command'->updateMeta
    switch Behavior.decide(state, command'.command) {
    | Ok(generatedEvents) =>
      let newState = generatedEvents->Array.reduce(state, Behavior.evolve)
      (newState, Array.concat(outcomes, [(reference, CmdOk(generatedEvents), meta)]))
    | Error(error) =>
      let errorJson = error->Message.encode(Spec.errorSchema)
      let errorCode = errorJson->Message.variantNameOfJson
      // Strip the TAG so detail carries only the rejection payload (empty for unit errors).
      let (_, payloadDict) = errorJson->Message.splitMessage
      let errorDetail =
        payloadDict->Dict.toArray->Array.length == 0
          ? ""
          : payloadDict->JSON.Encode.object->JSON.stringify
      let id = command'.id->Spec.Id.toString
      EffectLogger.logError(
        ~comp,
        `decide rejected: ${errorCode} ${errorDetail} id=${id}`,
      )->Effect.runSync
      (state, Array.concat(outcomes, [(reference, CmdRejected({errorCode, errorDetail}), meta)]))
    }
  }

  let maxConflictRetries = 3

  // Reports per-command outcomes on the inline side-channels and produces the
  // per-reference Ok/Error array consumed by SQS-style consumers. Domain rejections
  // are always Ok(reference) — SQS deletes the message because retry would not help —
  // and the rich error code/detail flows to producers via reportRejected.
  let reportFinalOutcomes = (
    outcomes: array<(string, cmdOutcome, Message.meta)>,
    ~entityId: string,
    ~appendSucceeded: bool,
    ~appendedEventCount: int,
  ): array<result<string, string>> =>
    outcomes->Array.map(((reference, outcome, _meta)) =>
      switch outcome {
      | CmdRejected({errorCode, errorDetail}) =>
        CommandTopic_Helpers.reportRejected(reference, {errorCode, errorDetail})
        Ok(reference)
      | CmdOk(_) if appendSucceeded =>
        CommandTopic_Helpers.reportAccepted(reference, {entityId, eventCount: appendedEventCount})
        Ok(reference)
      | CmdOk(_) => Error(reference)
      }
    )

  // Replays the event log, processes commands, and attempts to append.
  // Returns Ok(references) on success or non-conflict failure (per-reference Ok/Error
  // reflects per-command success), Error("conflict") on optimistic-locking failure
  // (caller retries the whole replay+process+append cycle).
  let replayProcessAppend = (
    id,
    topicItemsForId: array<CommandTopic.topicItem<Message.command'<Spec.Id.t, Spec.command>>>,
  ) => {
    let idStr = id->Spec.Id.toString

    Ops.eventLog.replayStream(id)
    ->Stream.runFold((Behavior.initialState, 0), ((st, n), ev) => (Behavior.evolve(st, ev), n + 1))
    ->Effect.tap(((_, n)) =>
      EffectLogger.logInfo(~comp, `replay: id=${idStr}, ${n->Int.toString} event(s)`)
    )
    ->Effect.flatMap(((initialState, sequenceNr)) => {
      let (_finalState, outcomes) =
        topicItemsForId->Array.reduce((initialState, []), processCommand)

      let eventsToAppend =
        outcomes
        ->Array.map(((_reference, outcome, meta)) =>
          switch outcome {
          | CmdOk(events) => events->Array.map(event => {Message.id, meta, event})
          | CmdRejected(_) => []
          }
        )
        ->Array.flat

      switch eventsToAppend {
      | [] =>
        let perRef = reportFinalOutcomes(
          outcomes,
          ~entityId=idStr,
          ~appendSucceeded=true,
          ~appendedEventCount=0,
        )
        EffectLogger.logInfo(~comp, `no events produced: id=${idStr}`)->Effect.map(_ => Ok(perRef))
      | generatedEvents' =>
        let eventCount = generatedEvents'->Array.length->Int.toString
        let eventDetails =
          generatedEvents'->Array.map(event' => event'->eventDetail)->Array.join(", ")
        let eventJsons = generatedEvents'->Array.map(event' => event'->eventJson)->JSON.Encode.array
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
              let perRef = reportFinalOutcomes(
                outcomes,
                ~entityId=idStr,
                ~appendSucceeded=true,
                ~appendedEventCount=generatedEvents'->Array.length,
              )
              EffectLogger.logInfo(~comp, `append: id=${idStr}`)->Effect.map(_ => Ok(perRef))
            | Error(msg) if msg->String.includes("conflict") =>
              EffectLogger.logWarn(~comp, `conflict: id=${idStr}, will retry`)->Effect.map(
                _ => Error("conflict"),
              )
            | Error(_) =>
              let perRef = reportFinalOutcomes(
                outcomes,
                ~entityId=idStr,
                ~appendSucceeded=false,
                ~appendedEventCount=0,
              )
              EffectLogger.logError(~comp, `append failed: id=${idStr}`)->Effect.map(_ => Ok(perRef))
            },
        )
      }
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
