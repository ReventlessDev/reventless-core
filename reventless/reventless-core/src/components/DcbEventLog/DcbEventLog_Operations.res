module type Ops = {
  module Spec: Reventless.DcbEventLog.Spec
  let name: string
  let storage: DcbEventLog_Adapter.operations
  let publishJson: EventTopic.publishJson
}

module type T = {
  module Spec: Reventless.DcbEventLog.Spec
  let read: DcbEventLog.read<Spec.event>
  let append: DcbEventLog.append<Spec.event>
  let readStream: DcbEventLog.readStream<Spec.event>
  let appendStream: DcbEventLog.appendStream<Spec.event>
}

module Make = (Spec: Reventless.DcbEventLog.Spec, Ops: Ops with module Spec = Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec
  let name = Ops.name

  let encodeEvent = (event: Spec.event): DcbEventLog_Adapter.rawStoredEvent => {
    let json = event->S.reverseConvertToJsonOrThrow(Spec.eventSchema)
    let (eventType, data) = json->Message.splitMessage
    let tags = Reventless.DcbTag.extractTags(Spec.eventSchema, event)
    {
      eventType,
      data: JSON.Object(data),
      tags,
    }
  }

  let decodeEvent = (raw: DcbEventLog_Adapter.rawSequencedEvent): DcbEventLog.sequencedEvent<
    Spec.event,
  > => {
    let json = Message.combineMessage(
      raw.eventType,
      raw.data->JSON.Decode.object->Option.getOr(Dict.make()),
    )
    let event = json->S.parseJsonOrThrow(Spec.eventSchema)
    {
      position: raw.position,
      event,
      tags: raw.tags,
    }
  }

  let publishToEventTopic = async (events: array<Spec.event>) => {
    let _ = await events
    ->Array.map(async event => {
      let json = event->S.reverseConvertToJsonOrThrow(Spec.eventSchema)
      let meta = Message.generateMeta(~service=name)
      try await Ops.publishJson(name, meta, json) catch {
      | JsExn(err) =>
        let errMsg = err->JsExn.message->Option.getOr("unknown")
        Effect.logError(`DcbEventLog(${name}): EventTopic.publish Error: ${errMsg}`)->Effect.runSync
      }
    })
    ->Promise.all
  }

  let append = async (
    events: array<Spec.event>,
    ~condition: option<Reventless.DcbTag.appendCondition>=?,
  ) => {
    let rawEvents = events->Array.map(encodeEvent)
    let result = await Ops.storage.append(rawEvents, ~condition?)
    switch result {
    | Ok(position) =>
      await publishToEventTopic(events)
      Ok(position)
    | Error(_) as err => err
    }
  }

  let read = async (
    ~query: Reventless.DcbTag.query,
    ~after: option<Reventless.DcbTag.sequencePosition>=?,
  ) => {
    let rawResult = await Ops.storage.read(~query, ~after?)
    let events = rawResult.events->Array.map(decodeEvent)
    let result: DcbEventLog.readResult<_> = {
      events,
      headPosition: ?rawResult.headPosition,
    }
    result
  }

  let readStream: DcbEventLog.readStream<Spec.event> = (~query, ~after=?) =>
    Ops.storage.readStream(~query, ~after?)->Stream.map(raw => decodeEvent(raw))

  // Streaming append — collects the stream into an array, then makes a single
  // storage.append call to preserve atomicity of the condition check.
  // Does not publish to EventTopic (use case: migration / bulk seeding).
  let appendStream: DcbEventLog.appendStream<Spec.event> = (stream, ~condition=?) =>
    stream
    ->Stream.map(event => encodeEvent(event))
    ->Stream.runCollect
    ->Effect.flatMap(rawEvents => Effect.promise(() => Ops.storage.append(rawEvents, ~condition?)))
}
