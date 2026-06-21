module type T = {
  module Spec: Reventless.StateChangeSlice.Spec
  module Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec
  let handleCommands: (
    ~tagKeysByEventType: Dict.t<array<string>>=?,
    ~crossPartitionTagKeys: array<string>=?,
    DcbEventLog.operations,
    Stream.t<
      CommandTopic.topicItem<Message.command'<Reventless.Id.String.t, Spec.command>>,
      string,
      unit,
    >,
  ) => Effect.t<array<result<string, string>>, string, unit>
  /** Flushes this slice's in-process decision-model projection cache. The cache
      is keyed on durable storage positions, so it must be cleared whenever the
      backing store is reset out-of-band (test isolation; operational flush). */
  let resetCache: unit => unit
}

module Make = (
  Spec: Reventless.StateChangeSlice.Spec,
  Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
): (T with module Spec = Spec and module Behavior := Behavior) => {
  module Spec = Spec
  module Behavior = Behavior

  let comp = `StateChangeSlice(${Spec.name})`

  let decoder = Reventless.DcbDecode.makeDecoder(Spec.consumedEventSchema)
  let queryEventTypes = decoder.eventTypes

  let encodeEvent = (
    ~parentMeta: Message.meta,
    event: Spec.event,
  ): ReventlessInfra.DcbEventLog.rawEvent => {
    let json = event->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow
    let (eventType, data) = json->Message.splitMessage
    // Use `extractTagsExpanded` (not `extractTags`) so per-element tags on
    // `array<string>` fields are emitted — e.g. OrderPlaced's
    // `productIds: array<string>` produces one tag per productId rather than
    // dropping the field entirely. The stored event then carries each productId
    // as a GSI tag attribute, so composite/GSI readers and the per-productId
    // partition (for events partitioned by productId) resolve correctly.
    //
    // Note: a productId here is a *secondary* tag on OrderPlaced (the partition
    // tag is orderId). The DynamoDB adapter fences a tag only when it is the
    // event's partition tag, so emitting productId tags does NOT bump
    // `fence#productId:<x>` — that fence is owned by productId-partitioned events
    // (e.g. CatalogProductSynced). This keeps read-scope and fence-scope aligned;
    // see `docs/analysis/dcb-consistency-check-issues.md`.
    let tags =
      Reventless.DcbTag.extractTagsExpanded(Spec.eventSchema, event)->Array.concat([
        {Reventless.DcbTag.key: "originatorSlice", value: Spec.name},
      ])
    // Inherit service from the triggering command — the DcbEventLog publish path
    // overrides service to `<name>DcbEventLog` for routing so EventCollector
    // subscriptions still match.
    let meta = Message.deriveMeta(~parent=parentMeta)
    {eventType, data: JSON.Object(data), tags, meta}
  }

  // Computed once at functor init — used to extract entityId for publishJsonsAndWait outcomes.
  let derivedPartitionTag = Reventless.DcbTag.derivePartitionTag([
    (Spec.name, Behavior.moduleUrl, Spec.eventSchema->S.castToUnknown),
  ])

  // Extracts the entity id of a read event from its own tags, for logging
  // which events the decision model was built from. Prefers this slice's
  // partition key (derived from the produced event), but consumed events from
  // other sources are tagged by their own key (e.g. CatalogProductSynced →
  // productId, not this slice's orderId), so fall back to the read event's own
  // tag value(s) instead of logging no id.
  let readEventId = (tags: array<Reventless.DcbTag.tag>): option<string> => {
    let ownTagValues = () => {
      // Skip the `originatorSlice` metadata tag that `encodeEvent` appends to
      // every stored event — it's the producing slice's name, not an entity id.
      let vals =
        tags
        ->Array.filter((t: Reventless.DcbTag.tag) => t.key != "originatorSlice")
        ->Array.reduce([], (acc, t: Reventless.DcbTag.tag) =>
          acc->Array.includes(t.value) ? acc : acc->Array.concat([t.value])
        )
      vals->Array.length == 0 ? None : Some(vals->Array.join(","))
    }
    switch derivedPartitionTag {
    | Simple(pt) =>
      switch tags->Array.findMap((t: Reventless.DcbTag.tag) =>
        t.key == pt.key ? Some(t.value) : None
      ) {
      | Some(v) => Some(v)
      | None => ownTagValues()
      }
    | Composite(spec) => Some(Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec))
    }
  }

  let maxRetries = 3

  // In-process decision-model projection cache (per warm Lambda instance, per
  // slice). Keyed on the serialised DCB query, it holds the
  // `(decisionState, readHead)` the previous command for that query derived.
  //
  // On a hit, `handleSingleCommand` seeds the fold from the cached state and
  // reads only events *after* `readHead` (the delta) instead of folding full
  // history — O(delta) instead of O(history) per warm same-entity command.
  //
  // What is cached is deliberately the state the slice *decided on* and the head
  // it *read up to* — NOT the events this command produced, and NOT the
  // position `append` returned. The produced events are read back by the next
  // command's delta read (their position is always > readHead on both the
  // DynamoDB and in-memory backends), so the cache never needs to fold produced
  // events (sidestepping the consumedEvent/event type split) nor trust the
  // append position (which is the batch *base* on DynamoDB but the batch *max*
  // in-memory). Correctness still rests entirely on the conditional append's
  // fence: a stale cached state only changes the *decision*, and a stale
  // decision conflicts at append time → retry → re-read refreshes the state.
  //
  // Capacity is fixed at 100 entries; a per-slice knob is a future refinement
  // (see the plan's Step 4).
  let projectionCacheCapacity = 100
  let projectionCache: Lru.t<
    string,
    (Behavior.state, option<Reventless.DcbTag.sequencePosition>),
  > = Lru.make(~capacity=projectionCacheCapacity)

  let resetCache = () => projectionCache->Lru.clear

  // Processes one command against the DCB event log with optimistic concurrency:
  //   1. Reads relevant events (filtered by command tags) to build the decision
  //      model — seeded from the projection cache when warm, so only events after
  //      the cached head are read (delta), else the full history (cold)
  //   2. Decodes raw events using consumedEventSchema
  //   3. Calls Behavior.decide to produce new events
  //   4. Encodes produced events to raw and appends with a condition
  //   5. On conflict, retries from step 1 (up to maxRetries)
  let handleSingleCommand = (
    ~tagKeysByEventType,
    ~crossPartitionTagKeys,
    dcbEventLog: DcbEventLog.operations,
    command': Message.command'<Reventless.Id.String.t, Spec.command>,
  ) => {
    let cmdJson =
      command'->Message.commandJsonOfCommand'(
        ~idToString=Reventless.Id.String.toString,
        ~commandSchema=Spec.commandSchema,
      )
    // Render `Name({fields})` without the standalone command id: for DCB slice
    // commands the id is the entity/partition id, which is already shown among
    // the fields, so a leading `(id)` would just duplicate it.
    EffectLogger.logInfo(
      ~comp,
      ~detail=cmdJson.commandJson,
      `handling command: ${cmdJson->LogFormat.cmdDetailNoId}`,
    )->Effect.runSync

    let query = Reventless.DcbTag.buildQueryFromCommand(
      ~eventTypes=queryEventTypes,
      ~schema=Spec.commandSchema,
      ~value=command'.command,
      ~tagKeysByEventType,
      ~crossPartitionTagKeys,
    )

    // Log the DCB query parameters — the OR clauses (event types + tags) the
    // read below filters on. Constant across retries, so logged once per command.
    let queryDetail =
      query
      ->Array.map((qi: Reventless.DcbTag.queryItem) => {
        let types = switch qi.eventTypes {
        | Some(ts) => ts->Array.map(LogFormat.bold)->Array.join("|")
        | None => "*"
        }
        let tags = switch qi.tags {
        | Some(ts) =>
          ts->Array.map((t: Reventless.DcbTag.tag) => `${t.key}=${t.value}`)->Array.join(",")
        | None => ""
        }
        tags == "" ? types : `${types}{${tags}}`
      })
      ->Array.join(" OR ")
    EffectLogger.logInfo(~comp, `query: ${queryDetail}`)->Effect.runSync

    // Extract the entity ID from the command for use in Accepted outcomes.
    let entityId = switch derivedPartitionTag {
    | Simple(pt) => Reventless.DcbTag.getPartitionTagValue(query, pt)
    | Composite(spec) =>
      let tags = Reventless.DcbTag.extractTags(Spec.commandSchema, command'.command)
      Some(Reventless.DcbTag.getCompositePartitionKeyValue(tags, spec))
    }

    let cacheKey = query->JSON.stringifyAny->Option.getOr("")

    // Working seed across retries: the `(state, head)` the read folds from.
    // Starts from the projection cache (warm) or empty (cold); the conflict
    // branch re-seeds it with the just-read `(state, head)` so each retry reads
    // only the delta the conflicting writer added rather than full history.
    let seed = ref(Lru.get(projectionCache, cacheKey))

    let rec attempt = (~retries) => {
      let (baseState, afterPos) = switch seed.contents {
      | Some((state, head)) => (state, head)
      | None => (Behavior.initialState, None)
      }
      let cacheHit = seed.contents->Option.isSome

      // Consistency: governed by the slice's build-time `readConsistency` mode
      // (default `EscalateOnRetry`). Correctness is identical in every mode — the
      // conditional append's fence is always evaluated strongly, so a stale read
      // can only cost a rejected append (then a retry), never a wrong write. The
      // mode is a per-slice RCU/latency lever against replica-lag conflicts.
      //   EscalateOnRetry — eventual on the first attempt (cheaper RCU), then
      //     strong on every retry so a replica-lag conflict self-heals.
      //   AlwaysStrong    — strong every attempt (known-hot slices).
      //   AlwaysEventual  — eventual every attempt (cost-sensitive, low-contention).
      let strongConsistency = switch Spec.readConsistency {
      | Reventless.ReadConsistency.EscalateOnRetry => retries < maxRetries
      | AlwaysStrong => true
      | AlwaysEventual => false
      }

      dcbEventLog.readStream(~query, ~after=?afterPos, ~strongConsistency)
      ->Stream.map(raw => {
        let decoded = decoder.decode(
          ~eventType=raw.eventType,
          ~data=raw.data->JSON.Decode.object->Option.getOr(Dict.make()),
        )
        decoded->Option.map(event => (event, raw.position, raw.eventType, readEventId(raw.tags)))
      })
      ->Stream.flatMap(opt =>
        switch opt {
        | Some(v) => Stream.fromIterable([v])
        | None => Stream.empty
        }
      )
      // The head accumulator starts at `afterPos` (the seeded head), not `None`,
      // so an empty delta read keeps the cached head — the append must condition
      // on the head that actually exists, not assert "no events exist yet".
      ->Stream.runFold((baseState, afterPos, []), (
        (dm, _pos, reads),
        (event, position, eventType, eventId),
      ) => (
        Behavior.evolve(dm, event),
        Some(position),
        reads->Array.concat([
          switch eventId {
          | Some(id) => `${eventType->LogFormat.bold}(${id})`
          | None => eventType->LogFormat.bold
          },
        ]),
      ))
      ->Effect.tap(((_, _, reads)) =>
        EffectLogger.logInfo(
          ~comp,
          `read${cacheHit ? " (cached, delta)" : ""}: ${reads->Array.length->Int.toString} event(s)${reads->Array.length == 0
              ? ""
              : ` [${reads->Array.join(", ")}]`}`,
        )
      )
      ->Effect.flatMap(((state, headPosition, _)) =>
        EffectLogger.logDebug(
          ~comp,
          `deciding on state: ${state->JSON.stringifyAny->Option.getOr("<unserializable>")}`,
        )->Effect.flatMap(_ =>
          switch Behavior.decide(state, command'.command) {
          | Ok(newEvents) if newEvents->Array.length == 0 =>
            // No append, but the read snapshot is valid — cache it for the next command.
            Lru.put(projectionCache, cacheKey, (state, headPosition))
            CommandTopic_Helpers.reportAccepted(
              cmdJson.meta.msgId,
              switch entityId {
              | Some(eid) => {entityId: eid, eventCount: 0}
              | None => {eventCount: 0}
              },
            )
            EffectLogger.logInfo(~comp, "no events produced")->Effect.map(_ => Ok("ok"))
          | Ok(newEvents) =>
            let rawEvents = newEvents->Array.map(e => encodeEvent(~parentMeta=command'.meta, e))
            let eventCount = rawEvents->Array.length->Int.toString
            let eventDetails =
              rawEvents
              ->Array.map(
                e => {
                  let fields = switch e.data {
                  | Object(dict) =>
                    let f =
                      dict
                      ->Dict.toArray
                      ->Array.map(((k, v)) => `${k}:${v->JSON.stringify}`)
                      ->Array.join(",")
                    f == "" ? "" : `({${f}})`
                  | _ => ""
                  }
                  `${LogFormat.bold(e.eventType)}${fields}`
                },
              )
              ->Array.join(", ")
            let eventJsons = rawEvents->Array.map(e => e.data)->JSON.Encode.array
            let condition: Reventless.DcbTag.appendCondition = {
              query,
              after: ?headPosition,
            }
            EffectLogger.logInfo(
              ~comp,
              ~detail=eventJsons,
              `produced ${eventCount} event(s): [${eventDetails}]`,
            )
            ->Effect.flatMap(_ => Effect.promise(() => dcbEventLog.append(rawEvents, ~condition)))
            ->Effect.flatMap(
              appendResult =>
                switch appendResult {
                | Ok(_position) =>
                  // Cache the decided-on state at the read head (NOT including the
                  // events we just appended, and NOT the returned position): the
                  // next command's delta read picks our events up from `headPosition`.
                  Lru.put(projectionCache, cacheKey, (state, headPosition))
                  CommandTopic_Helpers.reportAccepted(
                    cmdJson.meta.msgId,
                    switch entityId {
                    | Some(eid) => {entityId: eid, eventCount: rawEvents->Array.length}
                    | None => {eventCount: rawEvents->Array.length}
                    },
                  )
                  EffectLogger.logInfo(~comp, `append: ${eventCount} event(s)`)->Effect.map(
                    _ => Ok("ok"),
                  )
                | Error(err) =>
                  if retries > 0 {
                    // Re-seed from the just-read snapshot so the retry reads only
                    // the delta the conflicting writer added, not full history.
                    seed := Some((state, headPosition))
                    // Per-slice CloudWatch counter: rising AppendRetry signals a
                    // slice feeling contention (the metric to watch the eventual
                    // default with — see dcb-high-contention-handling.md).
                    Metrics.emitCount(~metric="AppendRetry", ~slice=Spec.name)
                    EffectLogger.logWarn(
                      ~comp,
                      `append failed (retrying ${(maxRetries - retries + 1)
                          ->Int.toString}/${maxRetries->Int.toString}): ${err}`,
                    )->Effect.flatMap(_ => attempt(~retries=retries - 1))
                  } else {
                    // Retries exhausted — drop any cached snapshot so the next
                    // command for this entity takes the cold full-read path.
                    Lru.invalidate(projectionCache, cacheKey)
                    let errorCode = err->String.startsWith("Conflict") ? "Conflict" : "AppendFailed"
                    // A surfaced Conflict means the 3-retry loop could not absorb
                    // the contention — the operator signal for "this slice is hot"
                    // (consider sharding / async — Issue 10, §4 of the analysis).
                    if errorCode == "Conflict" {
                      Metrics.emitCount(~metric="AppendConflict", ~slice=Spec.name)
                    }
                    CommandTopic_Helpers.reportRejected(
                      cmdJson.meta.msgId,
                      {errorCode, errorDetail: err},
                    )
                    EffectLogger.logError(
                      ~comp,
                      `append failed, retries exhausted: ${err}`,
                    )->Effect.map(_ => Error(err))
                  }
                },
            )
          | Error(error) =>
            // Business-rule rejection — no append, but the read snapshot is valid; cache it.
            Lru.put(projectionCache, cacheKey, (state, headPosition))
            let errorJson = error->S.reverseConvertToJsonOrThrow(Spec.errorSchema)
            let errorCode = errorJson->Message.variantNameOfJson
            let (_, payloadDict) = errorJson->Message.splitMessage
            let errorDetail =
              payloadDict->Dict.toArray->Array.length == 0
                ? ""
                : payloadDict->JSON.Encode.object->JSON.stringify
            CommandTopic_Helpers.reportRejected(cmdJson.meta.msgId, {errorCode, errorDetail})
            EffectLogger.logError(
              ~comp,
              `decide rejected: ${errorCode} ${errorDetail}`,
            )->Effect.map(_ => Ok("rejected"))
          }
        )
      )
    }

    attempt(~retries=maxRetries)
  }

  // CommandTopic handler — processes each command sequentially through handleSingleCommand,
  // returning Ok(reference) or Error(reference) per command.
  let handleCommands = (~tagKeysByEventType=Dict.make(), ~crossPartitionTagKeys=[], dcbEventLog, stream) =>
    stream
    ->Stream.mapEffect(({ReventlessInfra.CommandTopic.reference: reference, command}) =>
      handleSingleCommand(~tagKeysByEventType, ~crossPartitionTagKeys, dcbEventLog, command)->Effect.map(result =>
        switch result {
        | Ok(_) => Ok(reference)
        | Error(_) => Error(reference)
        }
      )
    )
    ->Stream.runCollect
}
