module type Ops = {
  module Spec: Reventless.Aggregate.Spec
  module EventLog: EventLog.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventLog: EventLog.operations
}

module type T = {
  module Spec: Reventless.Aggregate.Spec
  let handleCommands: CommandTopic.commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  /** Flushes this aggregate's in-process replay cache. The cache is a pure read
      optimization (the OCC append fences staleness), so this is only needed for
      test isolation — production code never has to call it. */
  let resetCache: unit => unit
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

  // Derive meta for an event emitted from a command:
  //   - fresh msgId + time
  //   - correlationId, ip, user, traceparent, schemaVersion, headers inherited from the command
  //   - causationId = the command's msgId (the *direct* parent of this event)
  let updateMeta = (command': Message.command'<'id, 'command>) =>
    Message.deriveMeta(~parent=command'.meta)

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
    EffectLogger.logDebug(
      ~comp,
      `deciding on state: ${state->JSON.stringifyAny->Option.getOr("<unserializable>")}`,
    )->Effect.runSync
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

  // In-process replay cache (per warm Lambda instance, per aggregate — the
  // functor instance owns the cache, so the event log is implicit and the key
  // is just the aggregate id). Holds the `(state, sequenceNr)` the previous
  // command batch for that id left behind.
  //
  // On a hit, `replayProcessAppend` skips the event-log replay entirely and
  // decides on the cached state; after a successful append it stores the
  // already-folded post-append state (aggregates have no consumed-vs-produced
  // event split, so `evolve` over the appended events IS the replay result).
  // Correctness rests on the append's optimistic-concurrency check: a stale
  // cached state only changes the *decision*, and a stale sequenceNr conflicts
  // at append time → the conflict branch invalidates the entry and the retry
  // replays cold. Mirrors the StateChangeSlice decision-model cache, including
  // the fixed capacity (a per-aggregate knob is a future refinement — see
  // docs/plans/aggregate-snapshotting.md).
  let replayCacheCapacity = 100
  let replayCache: Lru.t<string, (Behavior.state, int)> = Lru.make(
    ~capacity=replayCacheCapacity,
  )

  let resetCache = () => replayCache->Lru.clear

  // Reports per-command outcomes on the inline side-channels and produces the
  // per-reference Ok/Error array consumed by SQS-style consumers. Domain rejections
  // are always Ok(reference) — SQS deletes the message because retry would not help —
  // and the rich error code/detail flows to producers via reportRejected.
  let reportFinalOutcomes = (
    outcomes: array<(string, cmdOutcome, Message.meta)>,
    ~entityId: string,
    ~appendSucceeded: bool,
    ~appendedEventCount: int,
    ~appendErrorDetail: string="",
  ): array<result<string, string>> =>
    outcomes->Array.map(((reference, outcome, _meta)) =>
      switch outcome {
      | CmdRejected({errorCode, errorDetail}) =>
        CommandTopic_Helpers.reportRejected(reference, {errorCode, errorDetail})
        Ok(reference)
      | CmdOk(_) if appendSucceeded =>
        CommandTopic_Helpers.reportAccepted(reference, {entityId, eventCount: appendedEventCount})
        Ok(reference)
      | CmdOk(_) =>
        CommandTopic_Helpers.reportRejected(
          reference,
          {errorCode: "AppendFailed", errorDetail: appendErrorDetail},
        )
        Error(reference)
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

    // Warm path: seed from the replay cache and skip the event-log read; the
    // OCC append below fences any staleness. Cold path: full replay as before.
    let readState = switch replayCache->Lru.get(idStr) {
    | Some((state, seqNr)) =>
      EffectLogger.logInfo(
        ~comp,
        `replay skipped (cached): id=${idStr}, seq=${seqNr->Int.toString}`,
      )->Effect.map(_ => (state, seqNr))
    | None =>
      Ops.eventLog.replayStream(id)
      ->Stream.runFold((Behavior.initialState, 0), ((st, n), ev) => (Behavior.evolve(st, ev), n + 1))
      ->Effect.tap(((_, n)) =>
        EffectLogger.logInfo(~comp, `replay: id=${idStr}, ${n->Int.toString} event(s)`)
      )
    }

    readState
    ->Effect.flatMap(((initialState, sequenceNr)) => {
      let (finalState, outcomes) =
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
        // Nothing appended, but the read snapshot is valid — keep it warm for
        // the next command (also refreshes recency on a cache hit).
        replayCache->Lru.put(idStr, (initialState, sequenceNr))
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
              // The post-decide fold state IS the post-append replay result;
              // cache it so the next command for this id skips the replay.
              replayCache->Lru.put(
                idStr,
                (finalState, sequenceNr + generatedEvents'->Array.length),
              )
              let perRef = reportFinalOutcomes(
                outcomes,
                ~entityId=idStr,
                ~appendSucceeded=true,
                ~appendedEventCount=generatedEvents'->Array.length,
              )
              EffectLogger.logInfo(~comp, `append: id=${idStr}`)->Effect.map(_ => Ok(perRef))
            | Error(EventLog.Conflict) =>
              // Another writer advanced the stream past our (possibly cached)
              // sequenceNr — drop the entry so the retry replays cold.
              replayCache->Lru.invalidate(idStr)
              // Signal the outer replay+re-decide retry loop (which matches
              // Error(_)); the string is an internal marker, no longer a
              // cross-component substring sentinel.
              EffectLogger.logWarn(~comp, `conflict: id=${idStr}, will retry`)->Effect.map(
                _ => Error("conflict"),
              )
            | Error(EventLog.StorageFailure(msg)) =>
              // Appends are atomic, so the read snapshot is likely still valid —
              // but a storage error means we can't be sure what committed;
              // drop the entry so the next attempt reads authoritative state.
              replayCache->Lru.invalidate(idStr)
              let perRef = reportFinalOutcomes(
                outcomes,
                ~entityId=idStr,
                ~appendSucceeded=false,
                ~appendedEventCount=0,
                ~appendErrorDetail=msg,
              )
              EffectLogger.logError(~comp, `append failed: id=${idStr}: ${msg}`)->Effect.map(_ => Ok(perRef))
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
                | Error(msg) =>
                  let detail = `concurrent modification (${maxConflictRetries->Int.toString} retries exhausted): ${msg}`
                  EffectLogger.logError(
                    ~comp,
                    `max conflict retries exhausted id=${idStr}: ${msg}`,
                  )->Effect.map(_ => references->Array.map(_ => Error(detail)))
                },
            )
          attempt(0)
        }),
        {"concurrency": "unbounded"},
      )->Effect.map(Array.flat)
    )
}
