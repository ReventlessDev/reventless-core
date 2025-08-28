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

  let splitEncodedEvent = json =>
    switch json->Js.Json.decodeObject {
    | Some(eventDict) =>
      let (tags, payload) =
        eventDict->Dict.toArray->Belt.Array.partition(((key, _)) => key == "TAG")
      let eventType = switch tags[0] {
      | Some((_, String(t))) => t
      | _ => "Unknown"
      }
      (eventType, payload->Dict.fromArray)
    | _ => ("Unknown", Dict.make())
    }

  let encodeEvent' = (id, event') => {
    let json = event'.ReventlessSpec.Message.event->Message.encode(Spec.eventSchema)
    let (eventType, data) = json->splitEncodedEvent
    [
      ("id", id->Message.encode(Spec.Id.schema)),
      (
        "sequenceNr",
        Js.Json.string(Message.hrtimeToString(~hrtime=Message.hrtime(), ~now=Message.now())),
      ),
      ("type", JSON.String(eventType)),
      ("data", JSON.Object(data)),
    ]
    ->Array.concat(event'.meta->Message.decomposeMeta)
    ->Js.Dict.fromArray
    ->Js.Json.object_
  }

  let encodeEvents' = (events', id) => events'->Array.map(event => encodeEvent'(id, event))

  let storageAppendErrorHandler = (id, err) => {
    let errMsg =
      `EventLog: Error: Couldn't append for ${Spec.name}(${id->Spec.Id.toString}):` ++
      err->Util.Error.message
    Js.log(errMsg)
    errMsg->Error
  }

  let publishToEventTopic = async (id, events') => {
    try await Ops.eventTopic.publish(events') catch {
    | Js.Exn.Error(err) =>
      let msg = `EventLog.appendFn(${id->Spec.Id.toString}): EventTopic.publish Error: `
      Js.log2(msg, err)
      Js.Exn.raiseError(msg ++ err->Js.Exn.message->Option.getOr("no error message given"))
    }
  }

  let catchErrorHandler = exn => {
    Js.log2("EventLog.append: Error:", exn)
    raise(exn)
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
      | exception Js.Exn.Error(e) => storageAppendErrorHandler(id, e)
      }
    } catch {
    | exn => catchErrorHandler(exn)
    }
  }

  let combineEvent = (eventType, data) => {
    JSON.Object([("TAG", JSON.String(eventType))]->Array.concat(data->Dict.toArray)->Dict.fromArray)
  }

  let decodeEvent = (id, json) =>
    try {
      Js.Json.decodeObject(json)
      ->Option.map(dict =>
        switch (dict->Dict.get("type"), dict->Dict.get("data")) {
        | (Some(JSON.String(eventType)), Some(JSON.Object(data))) => combineEvent(eventType, data)
        | (Some(JSON.String(eventType)), None) => combineEvent(eventType, Dict.make())
        | _ => Js.Exn.raiseError("event type or data incorrect")
        }
      )
      ->Option.getExn
      ->Message.decode(Spec.eventSchema)
    } catch {
    | Js.Exn.Error(e) =>
      let eventStr = json->Js.Json.stringify
      let message = e->Util.Error.message
      Js.Exn.raiseError(`EventLog.replay: Error: id:${id}: Couldn't decode ${eventStr}: ${message}`)
    }

  let decodeEvents = (jsons, id) => jsons->Array.map(json => decodeEvent(id, json))

  let replay = async id => {
    let eventsJson = await Ops.storage.replay(id->Spec.Id.toString)
    eventsJson->decodeEvents(id->Spec.Id.toString)
  }
}
