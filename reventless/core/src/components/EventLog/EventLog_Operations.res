module type Ops = {
  module Spec: ReventlessInfra.EventLog.T
  module EventTopic: EventTopic.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventTopic: EventTopic.operations
  let storage: EventLog_Adapter.operations
}

module type T = {
  module Spec: ReventlessInfra.EventLog.T
  let append: EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>
  let replay: EventLog.replay<Spec.Id.t, Spec.event>
  let replayStream: EventLog.replayStream<Spec.Id.t, Spec.event>
  let replayEnvelopes: EventLog.replayEnvelopes<Spec.Id.t, Spec.event>
  let appendStream: EventLog.appendStream<Spec.Id.t, Spec.event>
  let latestSnapshot: EventLog.latestSnapshot<Spec.Id.t>
  let writeSnapshot: EventLog.writeSnapshot<Spec.Id.t>
}

// Retry schedule for transient storage errors.
// Exponential backoff: 100ms, ~200ms, ~400ms, ~800ms, ~1600ms — max 5 retries.
// Only retries on recognized transient error messages; permanent errors propagate immediately.
// Retry only recognized transient storage failures — never a Conflict (a retry
// of the same append would just conflict again; the OCC retry happens a layer up
// via replay+re-decide).
let isTransient = (e: EventLog.appendError) =>
  switch e {
  | EventLog.Conflict => false
  | StorageFailure(msg) =>
    msg->String.includes("ThrottlingException") ||
    msg->String.includes("ProvisionedThroughputExceededException") ||
    msg->String.includes("ServiceUnavailable") ||
    msg->String.includes("RequestLimitExceeded") ||
    msg->String.includes("InternalServerError")
  }

let storageRetrySchedule: Schedule.t<(Duration.t, int), EventLog.appendError, unit> =
  Schedule.exponential(Duration.millis(100))
  ->Schedule.jittered
  ->Schedule.intersect(Schedule.recurs(5))
  ->Schedule.whileInput(isTransient)

module Make = (Spec: ReventlessInfra.EventLog.T, Ops: Ops with module Spec = Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  // The stored item for an event already encoded and sealed: its type and fields.
  let storedEventOf = (id, sequenceNr, meta, (eventType, data)) => {
    let stored: Reventless.StoredEvent.storedEvent<Spec.Id.t> = {
      id,
      position: sequenceNr->Int.toString->String.padStart(9, "0"),
      event: eventType,
      data: JSON.Object(data),
      meta,
      recordedAt: Message.nowAsISOString(),
    }
    stored->Message.storedEventToFlatJson(Spec.Id.schema)
  }

  /**
  Every event encoded once and sealed once: the form both the stored item and the
  published message are built from. An encrypting provider draws a fresh nonce on
  every seal, so a second encode would publish a ciphertext the log does not hold.
  Refused, never degraded, when a personal field cannot be sealed or comes out
  unsealed; the message names the event type and the field, never the value.
  */
  let sealEvents = async (events': array<Message.event'<Spec.Id.t, Spec.event>>): result<
    array<(string, dict<JSON.t>)>,
    string,
  > => {
    let out = []
    let failure = ref(None)
    for i in 0 to events'->Array.length - 1 {
      if failure.contents->Option.isNone {
        let event' = events'->Array.getUnsafe(i)
        let (eventType, data) = event'.event->Message.encode(Spec.eventSchema)->Message.splitMessage
        // The aggregate is the subject of a field that names none.
        let streamId = event'.id->Spec.Id.toString
        switch await Reventless.Pii.sealData(Spec.eventSchema, ~eventType, ~streamId, data) {
        | Error(e) => failure := Some(`cannot seal ${eventType}: ${e->Reventless.Pii.errorMessage}`)
        | Ok(sealed) =>
          switch Reventless.Pii.unsealedField(Spec.eventSchema, ~eventType, sealed) {
          | Some(field) =>
            failure := Some(`refused ${eventType}: its personal field ${field} is not sealed`)
          | None => out->Array.push((eventType, sealed))
          }
        }
      }
    }
    switch failure.contents {
    | Some(msg) => Error(msg)
    | None => Ok(out)
    }
  }

  /** What the topic publishes for one sealed event: the envelope `encodeEvent'`
      writes, with the sealed fields rather than a second encode. */
  let publishedJsonOf = (id, meta, (eventType, data)) =>
    Dict.fromArray([
      ("id", id->Reventless.Util_Sury.toJson(Spec.Id.schema)),
      ("meta", meta->Message.encode(Message.metaSchema)),
      ("event", Message.combineMessage(eventType, data)),
    ])->JSON.Encode.object

  let makePublishedEvent = (idStr, eventsJson, meta): EventPublish_Callback.publishedEvent => {
    componentName: Spec.name,
    entityId: idStr,
    eventCount: eventsJson->Array.length,
    eventsJson,
    meta,
  }

  let runBeforePublishHook = async (idStr, eventsJson, meta) =>
    switch EventPublish_Callback.beforePublishHook.contents {
    | None => ()
    | Some(hook) =>
      try {
        let _ = await hook(makePublishedEvent(idStr, eventsJson, meta))
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`EventLog(${Spec.name})`,
          `beforePublishHook error: ${errMsg}`,
        )->Effect.runSync
      }
    }

  let runAfterPublishHook = async (idStr, eventsJson, meta) =>
    switch EventPublish_Callback.afterPublishHook.contents {
    | None => ()
    | Some(hook) =>
      try {
        let _ = await hook(makePublishedEvent(idStr, eventsJson, meta))
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        EffectLogger.logError(
          ~comp=`EventLog(${Spec.name})`,
          `afterPublishHook error: ${errMsg}`,
        )->Effect.runSync
      }
    }

  // Returns result<unit, string> — never throws. Publish failures are surfaced as Error.
  // Publishes the sealed form the log stored, never a fresh encode.
  let publishToEventTopic = async (
    id,
    events': array<Message.event'<_, _>>,
    sealed: array<(string, dict<JSON.t>)>,
    eventsJson,
  ) => {
    let idStr = id->Spec.Id.toString
    let firstEvent = events'->Array.getUnsafe(0)
    let meta = firstEvent.meta
    await runBeforePublishHook(idStr, eventsJson, meta)
    try {
      let count = events'->Array.length->Int.toString
      let _ = await events'
      ->Array.mapWithIndex(async (event', i) => {
        let json = publishedJsonOf(event'.id, event'.meta, sealed->Array.getUnsafe(i))
        let _ = await Ops.eventTopic.publishJson(idStr, event'.meta, json)
        EffectLogger.logInfo(
          ~comp=`EventTopic(${Spec.name})`,
          ~detail=json,
          `published event ${(i + 1)->Int.toString}/${count}: ${LogFormat.eventDetail(json)}`,
        )->Effect.runSync
      })
      ->Promise.all
      await runAfterPublishHook(idStr, eventsJson, meta)
      Ok()
    } catch {
    | JsExn(err) =>
      let msg =
        `EventLog.append(${idStr}): EventTopic.publish Error: ` ++
        err->JsExn.message->Option.getOr("no error message given")
      Error(msg)
    }
  }

  // append returns result<unit, EventLog.appendError> — never throws.
  // Transient storage failures are retried with exponential backoff (up to 5
  // times); a Conflict is returned immediately (retried a layer up), and other
  // failures propagate after retries are exhausted.
  let append = async (sequenceNr, id, events') =>
    switch await sealEvents(events') {
    | Error(msg) =>
      Error(
        EventLog.StorageFailure(
          `EventLog: Error: Couldn't append for ${Spec.name}(${id->Spec.Id.toString}): ${msg}`,
        ),
      )
    | Ok(sealed) =>
      let eventsJson =
        sealed->Array.mapWithIndex((part, i) =>
          storedEventOf(id, sequenceNr + i, (events'->Array.getUnsafe(i)).meta, part)
        )
      let idStr = id->Spec.Id.toString
      // A thrown storage error becomes a StorageFailure; a returned Error keeps its
      // typed variant. The Effect fails with the typed appendError so the schedule
      // can retry only transient failures, then we collapse the outcome back into a
      // result (no Cause stringification / substring matching).
      let storageEffect =
        Effect.tryPromise(
          ~catch=(err: unknown) => EventLog.StorageFailure(
            Util.Error.messageFromUnknown(err, "storage error"),
          ),
          () => Ops.storage.append(sequenceNr, idStr, eventsJson),
        )
        ->Effect.flatMap(result =>
          switch result {
          | Ok(_) => Effect.succeed()
          | Error(e) => Effect.fail(e)
          }
        )
        ->Effect.retry(storageRetrySchedule)
        ->Effect.map(_ => Ok())
        ->Effect.catchAll(e => Effect.succeed(Error(e)))
      switch await storageEffect->Effect.runPromise {
      | Ok() =>
        (
          await publishToEventTopic(id, events', sealed, eventsJson)
        )->Result.mapError(msg => EventLog.StorageFailure(msg))
      | Error(EventLog.Conflict) => Error(EventLog.Conflict)
      | Error(StorageFailure(msg)) =>
        Error(
          EventLog.StorageFailure(
            `EventLog: Error: Couldn't append for ${Spec.name}(${idStr}): ${msg}`,
          ),
        )
      }
    }

  let decodeEvent = (id, json) =>
    try {
      JSON.Decode.object(json)
      ->Option.map(dict =>
        switch (dict->Dict.get("event"), dict->Dict.get("data")) {
        | (Some(JSON.String(eventType)), Some(JSON.Object(data))) =>
          Message.combineMessage(eventType, data)
        | (Some(JSON.String(eventType)), None) => Message.combineMessage(eventType, Dict.make())
        | _ => JsError.throwWithMessage("event type or data incorrect")
        }
      )
      ->Option.getOrThrow
      ->Message.decode(Spec.eventSchema)
    } catch {
    | JsExn(e) =>
      let eventStr = json->JSON.stringify
      let message = e->Util.Error.message
      JsError.throwWithMessage(
        `EventLog.replay: Error: id:${id}: Couldn't decode ${eventStr}: ${message}`,
      )
    }

  let decodeEvents = (jsons, id) => jsons->Array.map(json => decodeEvent(id, json))

  // The stored item with its sealed personal fields opened by the installed
  // provider, so the decoder reads values and the markers of values that are gone.
  // Most items hold nothing sealed and come back as they are, without a promise.
  let sealedParts = json =>
    switch json->JSON.Decode.object {
    | Some(dict) =>
      switch (dict->Dict.get("event"), dict->Dict.get("data")) {
      | (Some(JSON.String(eventType)), Some(JSON.Object(data)))
        if Reventless.Pii.needsOpen(Spec.eventSchema, ~eventType, data) =>
        Some((dict, eventType, data))
      | _ => None
      }
    | None => None
    }

  let openStored = async (id, json) =>
    switch sealedParts(json) {
    | None => json
    | Some((dict, eventType, data)) =>
      switch await Reventless.Pii.openData(Spec.eventSchema, ~eventType, data) {
      | Ok(opened) =>
        let out = dict->Dict.copy
        out->Dict.set("data", JSON.Object(opened))
        JSON.Object(out)
      | Error(e) =>
        JsError.throwWithMessage(
          `EventLog.replay: Error: id:${id}: cannot open ${eventType}: ${e->Reventless.Pii.errorMessage}`,
        )
      }
    }

  let openAndDecode = (id, json) =>
    switch sealedParts(json) {
    | None => Effect.sync(() => decodeEvent(id, json))
    | Some(_) => Effect.promise(() => openStored(id, json))->Effect.map(j => decodeEvent(id, j))
    }

  let replay = async id => {
    let idStr = id->Spec.Id.toString
    let eventsJson = await Ops.storage.replay(idStr)
    let opened = []
    for i in 0 to eventsJson->Array.length - 1 {
      opened->Array.push(await openStored(idStr, eventsJson->Array.getUnsafe(i)))
    }
    opened->decodeEvents(idStr)
  }

  // Lazy streaming replay — decodes inside the effect so thrown exceptions
  // surface through the stream's error channel rather than as unhandled exceptions.
  let replayStream = (id, ~fromSeq=?) =>
    Ops.storage.replayStream(id->Spec.Id.toString, ~fromSeq?)->Stream.mapEffect(json =>
      openAndDecode(id->Spec.Id.toString, json)
    )

  // The stored item is the flat form `storedEventToFlatJson` writes: meta.* at the
  // top level, reassembled the way `flatJsonToStoredEvent` does.
  let decodeMeta = (id, json) =>
    try {
      json
      ->JSON.Decode.object
      ->Option.getOrThrow
      ->Message.composeMeta
      ->Reventless.Util_Sury.fromJson(Message.metaSchema)
    } catch {
    | exn =>
      JsError.throwWithMessage(
        `EventLog.replay: Error: id:${id}: Couldn't decode the event's meta: ${Reventless.Util_Sury.exnMessage(
            exn,
          )}`,
      )
    }

  let replayEnvelopes = (id, ~fromSeq=?) => {
    let idStr = id->Spec.Id.toString
    Ops.storage.replayStream(idStr, ~fromSeq?)->Stream.mapEffect(json =>
      openAndDecode(idStr, json)->Effect.map(event => {
        Reventless.Message.id,
        meta: decodeMeta(idStr, json),
        event,
      })
    )
  }

  // Snapshot passthrough — the state stays JSON at this layer; the consumer
  // (Aggregate_Callback) decodes it against its own state schema and hash-gates
  // staleness, so a drifted snapshot degrades to full replay, never to an error.
  let latestSnapshot = id => Ops.storage.latestSnapshot(id->Spec.Id.toString)

  let writeSnapshot = (id, snap) => Ops.storage.writeSnapshot(id->Spec.Id.toString, snap)

  // Streaming append — encodes each Spec.event to the {type, data} storage format
  // and writes sequentially via the storage adapter.
  // Accepts Spec.event items (symmetric with replayStream) to enable direct
  // replayStream → appendStream pipelines without an intermediate mapping step.
  let appendStream = (startingSeqNr, id, stream) =>
    Ops.storage.appendStream(
      startingSeqNr,
      id->Spec.Id.toString,
      // Sealed as `append` seals, so a copied stream stores no personal value in
      // the clear; a field that cannot be sealed fails the stream.
      stream->Stream.mapEffect(event =>
        Effect.promise(async () => {
          let (eventType, data) = event->Message.encode(Spec.eventSchema)->Message.splitMessage
          let sealed = switch await Reventless.Pii.sealData(
            Spec.eventSchema,
            ~eventType,
            ~streamId=id->Spec.Id.toString,
            data,
          ) {
          | Ok(sealed) => sealed
          | Error(e) =>
            JsError.throwWithMessage(
              `EventLog.appendStream: cannot seal ${eventType}: ${e->Reventless.Pii.errorMessage}`,
            )
          }
          [("event", JSON.String(eventType)), ("data", JSON.Object(sealed))]
          ->Dict.fromArray
          ->JSON.Encode.object
        })
      ),
    )
}
