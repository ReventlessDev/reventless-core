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

  // Persisted-snapshot configuration (docs/plans/aggregate-snapshotting.md).
  // `None` (the default) keeps full replay; `Some({interval, stateSchema})`
  // seeds cold replays from the latest persisted snapshot and writes a fresh
  // one every `interval` events. Snapshots are a read optimization only — the
  // OCC append remains the sole consistency primitive, so a missing, drifted,
  // or corrupt snapshot degrades silently to full replay.
  let snapshotConfig = Behavior.snapshot

  // Structural hash of the state schema, computed once. Stored on every written
  // snapshot and compared on read: a snapshot whose hash differs from the
  // current schema (a state-shape change since it was written) is ignored and
  // overwritten at the next boundary, so a redeploy that changes `type state`
  // can't decode stale bytes into the wrong shape. NOTE: this catches *shape*
  // drift only — a semantics-only `evolve` change with an unchanged state type
  // is invisible (see the plan's open question; for alpha, wipe snapshots on
  // such changes, consistent with the alpha-wipe-over-migration convention).
  let stateSchemaHash = switch snapshotConfig {
  | Some({stateSchema}) =>
    HashObj.hashDict(
      ~dict=Dict.fromArray([("state", SchemaWalker.describeSchema(stateSchema->Obj.magic))]),
      ~options={algorithm: SHA256},
    )
  | None => ""
  }

  // State ⇄ JSON via the configured stateSchema. Both swallow sury failures to
  // `None` — an unserializable state just skips the snapshot write, and an
  // undecodable snapshot falls back to full replay; neither can fail a command.
  let encodeState = (state: Behavior.state): option<JSON.t> =>
    switch snapshotConfig {
    | Some({stateSchema}) =>
      switch state->S.reverseConvertToJsonOrThrow(stateSchema) {
      | json => Some(json)
      | exception _ => None
      }
    | None => None
    }

  let decodeState = (json: JSON.t): option<Behavior.state> =>
    switch snapshotConfig {
    | Some({stateSchema}) =>
      switch json->S.parseJsonOrThrow(stateSchema) {
      | state => Some(state)
      | exception _ => None
      }
    | None => None
    }

  // Cold read (in-process cache miss): when snapshots are enabled, seed from the
  // latest persisted snapshot (hash-gated) and replay only the events after it;
  // otherwise replay full history from seq 0. Returns `(state, sequenceNr)` where
  // sequenceNr is the total event count (the OCC condition for the next append).
  let coldReadState = id => {
    let idStr = id->Spec.Id.toString
    let seedEffect = switch snapshotConfig {
    | None => Effect.succeed((Behavior.initialState, 0))
    | Some(_) =>
      Effect.promise(() => Ops.eventLog.latestSnapshot(id))
      ->Effect.map(snapResult =>
        switch snapResult {
        | Ok(Some(snap)) if snap.EventLog.schemaHash == stateSchemaHash =>
          switch decodeState(snap.state) {
          | Some(state) => (state, snap.seqNr)
          | None =>
            EffectLogger.logWarn(
              ~comp,
              `snapshot ignored (undecodable): id=${idStr}, seq=${snap.seqNr->Int.toString} — full replay`,
            )->Effect.runSync
            (Behavior.initialState, 0)
          }
        | Ok(Some(snap)) =>
          EffectLogger.logWarn(
            ~comp,
            `snapshot ignored (schema drift): id=${idStr}, seq=${snap.EventLog.seqNr->Int.toString} — full replay`,
          )->Effect.runSync
          (Behavior.initialState, 0)
        | Ok(None) => (Behavior.initialState, 0)
        | Error(msg) =>
          EffectLogger.logWarn(
            ~comp,
            `snapshot read failed (ignored): id=${idStr}: ${msg} — full replay`,
          )->Effect.runSync
          (Behavior.initialState, 0)
        }
      )
    }
    seedEffect->Effect.flatMap(((seedState, seedSeq)) =>
      Ops.eventLog.replayStream(id, ~fromSeq=seedSeq)
      ->Stream.runFold((seedState, seedSeq), ((st, n), ev) => (Behavior.evolve(st, ev), n + 1))
      ->Effect.tap(((_, n)) => {
        let detail =
          seedSeq > 0
            ? `(snapshot@${seedSeq->Int.toString}, ${(n - seedSeq)->Int.toString} delta event(s))`
            : `${n->Int.toString} event(s)`
        EffectLogger.logInfo(~comp, `replay: id=${idStr}, ${detail}`)
      })
    )
  }

  // Fire-and-forget snapshot write — never awaited, never fails the command. A
  // failed write just means the next cold replay reads a longer delta.
  let fireSnapshotWrite = (id, idStr, snap: EventLog.snapshot) => {
    let _ =
      Ops.eventLog.writeSnapshot(id, snap)
      ->Promise.then(result => {
        switch result {
        | Ok() =>
          EffectLogger.logDebug(
            ~comp,
            `snapshot written: id=${idStr}, seq=${snap.seqNr->Int.toString}`,
          )->Effect.runSync
        | Error(msg) =>
          EffectLogger.logWarn(
            ~comp,
            `snapshot write failed (ignored): id=${idStr}: ${msg}`,
          )->Effect.runSync
        }
        Promise.resolve()
      })
      ->Promise.catch(err => {
        let msg = err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logWarn(
          ~comp,
          `snapshot write threw (ignored): id=${idStr}: ${msg}`,
        )->Effect.runSync
        Promise.resolve()
      })
  }

  // Write a snapshot when this append crossed an `interval` boundary (a multiple
  // of interval lies in (oldSeq, newSeq]). Keep-one: on a batch that crosses
  // several boundaries we still write just the latest state at newSeq. No-op
  // when snapshots are disabled or the state can't be serialized.
  let maybeWriteSnapshot = (id, idStr, ~oldSeq, ~newSeq, state) =>
    switch snapshotConfig {
    | Some({interval}) if interval > 0 && newSeq / interval > oldSeq / interval =>
      switch encodeState(state) {
      | Some(stateJson) =>
        fireSnapshotWrite(id, idStr, {EventLog.seqNr: newSeq, state: stateJson, schemaHash: stateSchemaHash})
      | None =>
        EffectLogger.logWarn(
          ~comp,
          `snapshot skipped (state not serializable): id=${idStr}, seq=${newSeq->Int.toString}`,
        )->Effect.runSync
      }
    | _ => ()
    }

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
        CommandTopic_Helpers.reportRejected(
          ~component=Spec.name,
          ~cause=DomainRejection,
          reference,
          {errorCode, errorDetail},
        )
        Ok(reference)
      | CmdOk(_) if appendSucceeded =>
        CommandTopic_Helpers.reportAccepted(
          ~component=Spec.name,
          reference,
          {entityId, eventCount: appendedEventCount},
        )
        Ok(reference)
      | CmdOk(_) =>
        // The decision succeeded and the append did not — infrastructure, not the model.
        CommandTopic_Helpers.reportRejected(
          ~component=Spec.name,
          ~cause=InfrastructureFailure,
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

    // Warm path: seed from the in-process cache and skip both the snapshot read
    // and the event-log replay; the OCC append below fences any staleness. Cold
    // path (`coldReadState`): seed from the persisted snapshot when enabled, else
    // full replay.
    let readState = switch replayCache->Lru.get(idStr) {
    | Some((state, seqNr)) =>
      EffectLogger.logInfo(
        ~comp,
        `replay skipped (cached): id=${idStr}, seq=${seqNr->Int.toString}`,
      )->Effect.map(_ => (state, seqNr))
    | None => coldReadState(id)
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
              let newSeq = sequenceNr + generatedEvents'->Array.length
              replayCache->Lru.put(idStr, (finalState, newSeq))
              // Persist a snapshot if this append crossed an interval boundary
              // (fire-and-forget — never blocks or fails the command).
              maybeWriteSnapshot(id, idStr, ~oldSeq=sequenceNr, ~newSeq, finalState)
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
