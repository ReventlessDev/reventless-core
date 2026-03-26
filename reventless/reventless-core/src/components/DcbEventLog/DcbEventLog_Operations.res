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
    let _ = await rawEvents
    ->Array.map(async rawEvent => {
      let json = Message.combineMessage(
        rawEvent.eventType,
        rawEvent.data->JSON.Decode.object->Option.getOr(Dict.make()),
      )
      let meta = Message.generateMeta(~service=name)
      try await Ops.publishJson(name, meta, json) catch {
      | JsExn(err) =>
        let errMsg = err->JsExn.message->Option.getOr("unknown")
        Effect.logError(`DcbEventLog(${name}): EventTopic.publish Error: ${errMsg}`)->Effect.runSync
      }
    })
    ->Promise.all
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
