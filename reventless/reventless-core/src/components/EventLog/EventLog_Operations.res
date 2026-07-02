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
  let appendStream: EventLog.appendStream<Spec.Id.t, Spec.event>
}

// Retry schedule for transient storage errors.
// Exponential backoff: 100ms, ~200ms, ~400ms, ~800ms, ~1600ms — max 5 retries.
// Only retries on recognised transient error messages; permanent errors propagate immediately.
// Retry only recognised transient storage failures — never a Conflict (a retry
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

  let encodeEvent' = (id, sequenceNr, event') => {
    let json = event'.Reventless.Message.event->Message.encode(Spec.eventSchema)
    let (eventType, data) = json->Message.splitMessage
    let stored: Reventless.StoredEvent.storedEvent<Spec.Id.t> = {
      id,
      position: sequenceNr->Int.toString->String.padStart(9, "0"),
      event: eventType,
      data: JSON.Object(data),
      meta: event'.meta,
      recordedAt: Message.nowAsISOString(),
    }
    stored->Message.storedEventToFlatJson(Spec.Id.schema)
  }

  let encodeEvents' = (events', id, startingSeqNr) =>
    events'->Array.mapWithIndex((event, i) => encodeEvent'(id, startingSeqNr + i, event))

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
  let publishToEventTopic = async (id, events': array<Message.event'<_, _>>, eventsJson) => {
    let idStr = id->Spec.Id.toString
    let firstEvent = events'->Array.getUnsafe(0)
    let meta = firstEvent.meta
    await runBeforePublishHook(idStr, eventsJson, meta)
    try {
      let _ = await Ops.eventTopic.publish(events')
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
  let append = async (sequenceNr, id, events') => {
    let eventsJson = events'->encodeEvents'(id, sequenceNr)
    let idStr = id->Spec.Id.toString
    // A thrown storage error becomes a StorageFailure; a returned Error keeps its
    // typed variant. The Effect fails with the typed appendError so the schedule
    // can retry only transient failures, then we collapse the outcome back into a
    // result (no Cause stringification / substring matching).
    let storageEffect =
      Effect.tryPromise(
        ~catch=(err: unknown) =>
          EventLog.StorageFailure(Util.Error.messageFromUnknown(err, "storage error")),
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
      (await publishToEventTopic(id, events', eventsJson))->Result.mapError(msg => EventLog.StorageFailure(
        msg,
      ))
    | Error(EventLog.Conflict) => Error(EventLog.Conflict)
    | Error(StorageFailure(msg)) =>
      Error(EventLog.StorageFailure(`EventLog: Error: Couldn't append for ${Spec.name}(${idStr}): ${msg}`))
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

  let replay = async id => {
    let eventsJson = await Ops.storage.replay(id->Spec.Id.toString)
    eventsJson->decodeEvents(id->Spec.Id.toString)
  }

  // Lazy streaming replay — wraps decodeEvent in Effect.sync so thrown exceptions
  // surface through the stream's error channel rather than as unhandled exceptions.
  let replayStream = id =>
    Ops.storage.replayStream(id->Spec.Id.toString)
    ->Stream.mapEffect(json =>
      Effect.sync(() => decodeEvent(id->Spec.Id.toString, json))
    )

  // Streaming append — encodes each Spec.event to the {type, data} storage format
  // and writes sequentially via the storage adapter.
  // Accepts Spec.event items (symmetric with replayStream) to enable direct
  // replayStream → appendStream pipelines without an intermediate mapping step.
  let appendStream = (startingSeqNr, id, stream) =>
    Ops.storage.appendStream(
      startingSeqNr,
      id->Spec.Id.toString,
      stream->Stream.map(event => {
        let json = event->Message.encode(Spec.eventSchema)
        let (eventType, data) = json->Message.splitMessage
        [("event", JSON.String(eventType)), ("data", JSON.Object(data))]
        ->Dict.fromArray
        ->JSON.Encode.object
      }),
    )
}
