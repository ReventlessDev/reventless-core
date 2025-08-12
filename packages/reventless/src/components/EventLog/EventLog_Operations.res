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

  let eventToJson = (id, event') =>
    [
      ("id", id->Message.encode(Spec.Id.schema)),
      (
        "sequenceNr",
        Js.Json.string(Message.hrtimeToString(~hrtime=Message.hrtime(), ~now=Message.now())),
      ),
      ("event", event'.ReventlessSpec.Message.event->Message.encode(Spec.eventSchema)),
    ]
    ->Array.concat(event'.meta->Message.decomposeMeta)
    ->Js.Dict.fromArray
    ->Js.Json.object_

  let eventsToJson = (events', id) => events'->Array.map(event => eventToJson(id, event))

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
      let eventsJson = events'->eventsToJson(id)

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

  let decodeEvent = (id, json) =>
    try {
      Js.Json.decodeObject(json)
      ->Option.flatMap(dict => dict->Js.Dict.get("event"))
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
