module type Ops = {
  let name: string
  let storage: DcbEventLog_Adapter.operations
  let publishJson: EventTopic.publishJson
}

module type T = {
  let read: DcbEventLog.read
  let append: DcbEventLog.append
  let readStream: DcbEventLog.readStream
  let appendStream: DcbEventLog.appendStream
}

module Make = (Ops: Ops): T => {
  let name = Ops.name

  let publishToEventTopic = async (rawEvents: array<DcbEventLog.rawEvent>) => {
    let eventsJson = rawEvents->Array.map(rawEvent =>
      Message.combineMessage(
        rawEvent.eventType,
        rawEvent.data->JSON.Decode.object->Option.getOr(Dict.make()),
      )
    )
    let meta = Message.generateMeta(~service=name)

    // Run beforePublish hook — if it throws, log the error and publish original events.
    let finalEventsJson = switch EventPublish_Callback.beforePublishHook.contents {
    | None => eventsJson
    | Some(hook) =>
      let published: EventPublish_Callback.publishedEvent = {
        componentName: name,
        entityId: name,
        eventCount: eventsJson->Array.length,
        eventsJson,
        meta,
      }
      try {
        let result = await hook(published)
        result.eventsJson
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `DcbEventLog(${name}): beforePublishHook error: ${errMsg}`,
        )->Effect.runSync
        eventsJson
      }
    }

    let _ = await finalEventsJson
    ->Array.map(async json => {
      try await Ops.publishJson(name, meta, json) catch {
      | JsExn(err) =>
        let errMsg = err->JsExn.message->Option.getOr("unknown")
        Effect.logError(`DcbEventLog(${name}): EventTopic.publish Error: ${errMsg}`)->Effect.runSync
      }
    })
    ->Promise.all

    // Run afterPublish hook — fire-and-forget, errors are caught and logged.
    switch EventPublish_Callback.afterPublishHook.contents {
    | None => ()
    | Some(hook) =>
      try {
        let published: EventPublish_Callback.publishedEvent = {
          componentName: name,
          entityId: name,
          eventCount: finalEventsJson->Array.length,
          eventsJson: finalEventsJson,
          meta,
        }
        let _ = await hook(published)
      } catch {
      | err =>
        let errMsg =
          err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
        Effect.logError(
          `DcbEventLog(${name}): afterPublishHook error: ${errMsg}`,
        )->Effect.runSync
      }
    }
  }

  let append: DcbEventLog.append = async (
    rawEvents,
    ~condition=?,
  ) => {
    // Adapter rawStoredEvent is structurally identical to infra rawEvent
    let adapterEvents: array<DcbEventLog_Adapter.rawStoredEvent> = rawEvents->Obj.magic
    let result = await Ops.storage.append(adapterEvents, ~condition?)
    switch result {
    | Ok(position) =>
      await publishToEventTopic(rawEvents)
      Ok(position)
    | Error(_) as err => err
    }
  }

  let read: DcbEventLog.read = async (
    ~query,
    ~after=?,
  ) => {
    let rawResult = await Ops.storage.read(~query, ~after?)
    // Adapter rawSequencedEvent is structurally identical to infra rawSequencedEvent
    let events: array<DcbEventLog.rawSequencedEvent> = rawResult.events->Obj.magic
    let result: DcbEventLog.readResult = {
      events,
      headPosition: ?rawResult.headPosition,
    }
    result
  }

  let readStream: DcbEventLog.readStream = (~query, ~after=?) =>
    Ops.storage.readStream(~query, ~after?)->Stream.map(raw => (raw->Obj.magic: DcbEventLog.rawSequencedEvent))

  // Streaming append — collects the stream into an array, then makes a single
  // storage.append call to preserve atomicity of the condition check.
  // Does not publish to EventTopic (use case: migration / bulk seeding).
  let appendStream: DcbEventLog.appendStream = (stream, ~condition=?) =>
    stream
    ->Stream.map(rawEvent => (rawEvent->Obj.magic: DcbEventLog_Adapter.rawStoredEvent))
    ->Stream.runCollect
    ->Effect.flatMap(rawEvents => Effect.promise(() => Ops.storage.append(rawEvents, ~condition?)))
}
