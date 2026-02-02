module type Ops = {
  module Spec: EventLog.Spec
  module EventTopic: EventTopic.T with module Spec.Id = Spec.Id and type Spec.event = Spec.event
  let eventTopic: EventTopic.operations
  let storage: EventLog_Adapter.operations
}

module type T = {
  module Spec: EventLog.Spec
  let append: EventLog.append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>
  let replay: EventLog.replay<Spec.Id.t, Spec.event>
}

module Make = (Spec: EventLog.Spec, Ops: Ops with module Spec = Spec): (
  T with module Spec = Spec
) => {
  module Spec = Spec

  let encodeEvent' = (id, event') => {
    let json = event'.ReventlessSpec.Message.event->Message.encode(Spec.eventSchema)
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

  let storageAppendErrorHandler = (id, err) => {
    let errMsg =
      `EventLog: Error: Couldn't append for ${Spec.name}(${id->Spec.Id.toString}):` ++
      err->Util.Error.message
    Console.log(errMsg)
    errMsg->Error
  }

  let publishToEventTopic = async (id, events') => {
    try await Ops.eventTopic.publish(events') catch {
    | JsExn(err) =>
      let msg = `EventLog.appendFn(${id->Spec.Id.toString}): EventTopic.publish Error: `
      Console.log2(msg, err)
      JsError.throwWithMessage(msg ++ err->JsExn.message->Option.getOr("no error message given"))
    }
  }

  let catchErrorHandler = exn => {
    Console.log2("EventLog.append: Error:", exn)
    throw(exn)
  }

  // FIXME: append is supposed to return result<unit, string/*errorMessage*/>, but at the same moment, we throw errors
  //        We should use result everywhere instead of throwing errors / exceptions
  let append = async (
    sequenceNr: int,
    id: 'specId,
    events': array<Reventless.Message.event'<'specId, 'specEvent>>,
  ) => {
    try {
      let eventsJson = events'->encodeEvents'(id)

      switch await Ops.storage.append(sequenceNr, id->Spec.Id.toString, eventsJson) {
      | appendResult =>
        await publishToEventTopic(id, events')
        appendResult
      | exception JsExn(e) => storageAppendErrorHandler(id, e)
      }
    } catch {
    | exn => catchErrorHandler(exn)
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
