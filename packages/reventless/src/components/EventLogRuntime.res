let eventToJson = (specIdEncode, specEventEncode, id, event') =>
  [
    ("id", specIdEncode(id)),
    (
      "sequenceNr",
      Js.Json.string(Message.hrtimeToString(~hrtime=Message.hrtime(), ~now=Message.now())),
    ),
    ("event", event'.ReventlessSpec.Message.event->specEventEncode),
  ]
  ->Belt.Array.concat(event'.meta->Message.decomposeMeta)
  ->Js.Dict.fromArray
  ->Js.Json.object_

let eventsToJson = (events', specIdEncode, specEventEncode, id) =>
  events'->Belt.Array.map(eventToJson(specIdEncode, specEventEncode, id))

let storageAppendErrorHandler = (specName, specIdToString, id, err) => {
  let errMsg =
    `EventLog: Error: Couldn't append for ${specName}(${id->specIdToString}):` ++
    err->Js.Exn.message->Belt.Option.getWithDefault("no error message given")
  Js.log(errMsg)
  errMsg->Belt.Result.Error
}

let publishToEventTopic = async (eventTopicPublish, specIdToString, id, events') => {
  try await eventTopicPublish(. events') catch {
  | Js.Exn.Error(err) =>
    let msg = `EventLog.appendFn(${id->specIdToString}): EventTopic.publish Error: `
    Js.log2(msg, err)
    Js.Exn.raiseError(
      msg ++ err->Js.Exn.message->Belt.Option.getWithDefault("no error message given"),
    )
  }
}

let catchErrorHandler = exn => {
  Js.log2("EventLog.append: Error:", exn)
  raise(exn)
}

// FIXME: appendFn is supposed to return result<unit, string/*errorMessage*/>, but at the same moment, we throw errors
//        We should use result everywhere instead of throwing errors / exceptions
let appendFn = (
  storageAppend: EventLogCommon.append<string, Js.Json.t>,
  specIdToString: 'specId => string,
  specIdEncode: 'specId => Js.Json.t,
  specEventEncode: 'specEvent => Js.Json.t,
  eventTopicPublish: EventTopic.publish<'specId, 'specEvent>,
  specName: string,
) => async (.
  sequenceNr: int,
  id: 'specId,
  events': array<Reventless.Message.event'<'specId, 'specEvent>>,
) => {
  try {
    let eventsJson = events'->eventsToJson(specIdEncode, specEventEncode, id)

    switch await storageAppend(. sequenceNr, id->specIdToString, eventsJson) {
    | appendResult =>
      await publishToEventTopic(eventTopicPublish, specIdToString, id, events')
      appendResult
    | exception Js.Exn.Error(err) => storageAppendErrorHandler(specName, specIdToString, id, err)
    }
  } catch {
  | exn => catchErrorHandler(exn)
  }
}

let decodeEvent = (specEventDecode, json) =>
  Js.Json.decodeObject(json)
  ->Belt.Option.flatMap(dict => dict->Js.Dict.get("event"))
  ->Belt.Option.map(json => (json, specEventDecode(json)))
  ->Belt.Option.map(x =>
    switch x {
    | (_, Belt.Result.Ok(event)) => event
    | (json, Error(err: Decco.decodeError)) =>
      let eventStr = json->Js.Json.stringify
      let message = err.message
      Js.Exn.raiseError(`EventLog.replay: Error: Couldn't decode ${eventStr}: ${message}`)
    }
  )
  ->(
    x =>
      switch x {
      | Some(event) => event
      | None =>
        let eventStr = json->Js.Json.stringify
        Js.Exn.raiseError(`EventLog.replay: Error: Couldn't decodeObject ${eventStr}`)
      }
  )

let decodeEvents = (jsons, specEventDecode) => jsons->Belt.Array.map(decodeEvent(specEventDecode))

let decodeEventsToPromise: (
  Js.Json.t => result<'a, Decco.decodeError>,
  array<Js.Json.t>,
) => promise<array<'a>> = (specEventDecode, jsons) =>
  decodeEvents(jsons, specEventDecode)->Js.Promise2.resolve

let replayFn: (
  EventLogCommon.replay<string, Js.Json.t>,
  'specId => string,
  Js.Json.t => result<'specEvent, Decco.decodeError>,
) => (. 'specId) => promise<array<'specEvent>> = (
  storageReplay,
  specIdToString,
  specEventDecode,
) => async (. id) => {
  let jsonEvents = await storageReplay(. id->specIdToString)
  await decodeEventsToPromise(specEventDecode, jsonEvents)
}
