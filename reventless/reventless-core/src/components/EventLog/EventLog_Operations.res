module type Ops = {
  module Spec: Reventless.EventLog.T
  module EventTopic: EventTopic.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventTopic: EventTopic.operations
  let storage: EventLog_Adapter.operations
}

module type T = {
  module Spec: Reventless.EventLog.T
  let append: EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>
  let replay: EventLog.replay<Spec.Id.t, Spec.event>
}

module Make = (Spec: Reventless.EventLog.T, Ops: Ops with module Spec = Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  let encodeEvent' = (id, event') => {
    let json = event'.Reventless.Message.event->Message.encode(Spec.eventSchema)
    let (eventType, data) = json->Message.splitMessage
    [
      ("id", id->Message.encode(Spec.Id.schema)),
      (
        "sequenceNr",
        JSON.Encode.string(Message.hrtimeToString(~hrtime=Message.hrtime(), ~now=Message.now())),
      ),
      ("type", JSON.String(eventType)),
      ("data", JSON.Object(data)),
    ]
    ->Array.concat(event'.meta->Message.decomposeMeta)
    ->Dict.fromArray
    ->JSON.Encode.object
  }

  let encodeEvents' = (events', id) => events'->Array.map(event => encodeEvent'(id, event))

  // Returns result<unit, string> — never throws. Publish failures are surfaced as Error.
  let publishToEventTopic = async (id, events') => {
    try {
      let _ = await Ops.eventTopic.publish(events')
      Ok()
    } catch {
    | JsExn(err) =>
      let msg =
        `EventLog.append(${id->Spec.Id.toString}): EventTopic.publish Error: ` ++
        err->JsExn.message->Option.getOr("no error message given")
      Error(msg)
    }
  }

  // append returns result<unit, string> — never throws.
  // Storage errors (including exceptions) and publish errors are surfaced as Error values.
  let append = async (sequenceNr, id, events') => {
    let eventsJson = events'->encodeEvents'(id)
    let idStr = id->Spec.Id.toString
    switch await Ops.storage.append(sequenceNr, idStr, eventsJson) {
    | Ok(_) => await publishToEventTopic(id, events')
    | Error(msg) =>
      Error(`EventLog: Error: Couldn't append for ${Spec.name}(${idStr}): ${msg}`)
    | exception JsExn(e) =>
      Error(
        `EventLog: Error: Couldn't append for ${Spec.name}(${idStr}): ` ++ e->Util.Error.message,
      )
    }
  }

  let decodeEvent = (id, json) =>
    try {
      JSON.Decode.object(json)
      ->Option.map(dict =>
        switch (dict->Dict.get("type"), dict->Dict.get("data")) {
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
}
