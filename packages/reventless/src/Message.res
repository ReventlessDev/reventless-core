module type Service = {
  module Id: ReventlessSpec.Id.T

  @schema
  type id = Id.t

  @schema
  type command
  @schema
  type event
  @schema
  type error

  let name: string
}

include ReventlessSpec.Message

let decode = (json, schema: S.t<'a>) => json->S.parseJsonOrThrow(schema)
let encode = (value, schema: S.t<'a>) => value->S.reverseConvertToJsonOrThrow(schema)

let toEventSchema' = (idSchema, eventSchema) =>
  S.object(s => {
    id: s.field("id", idSchema),
    meta: s.field("meta", metaSchema),
    event: s.field("event", eventSchema),
  })
let toCommandSchema' = (idSchema, commandSchema) =>
  S.object(s => {
    id: s.field("id", idSchema),
    meta: s.field("meta", metaSchema),
    command: s.field("command", commandSchema),
  })

let decodeEvent' = (json, idSchema, eventSchema) =>
  json->S.parseJsonOrThrow(toEventSchema'(idSchema, eventSchema))
let decodeCommand' = (json, idSchema, commandSchema) =>
  json->S.parseJsonOrThrow(toCommandSchema'(idSchema, commandSchema))

let encodeEvent' = (event', idSchema, eventSchema) =>
  event'->S.reverseConvertToJsonOrThrow(toEventSchema'(idSchema, eventSchema))
let encodeCommand' = (command', idSchema, commandSchema) =>
  command'->S.reverseConvertToJsonOrThrow(toCommandSchema'(idSchema, commandSchema))

let uuid = Uuid.v4

let log: ('a, string) => 'a = (value, str) => {
  Js.log2(str, value)
  value
}

let now = () => Js.Date.make()->Js.Date.getTime

let nowAsISOString = () => Js.Date.make()->Js.Date.toISOString

type handler<'msg> = 'msg => Js.Promise.t<unit>

let toMessageBody = ({id, meta, commandJson}) => {
  let commandMeta: meta = {...meta, msgId: uuid(), time: nowAsISOString()}
  [
    ("id", id->Js.Json.string),
    ("meta", commandMeta->S.reverseConvertToJsonOrThrow(metaSchema)),
    ("command", commandJson),
  ]
  ->Js.Dict.fromArray
  ->Js.Json.object_
  ->Js.Json.stringify
}

type commandHandler<'id, 'command> = command'<'id, 'command> => Js.Promise.t<unit>

type commandsHandler<'id, 'command> = ('id, array<command'<'id, 'command>>) => Js.Promise.t<unit>

let serviceNameOfMsg = msgJson =>
  switch msgJson->Js.Json.decodeObject {
  | Some(msgObj) =>
    msgObj
    ->Js.Dict.get("meta")
    ->Option.flatMap(meta =>
      switch meta->S.parseJsonOrThrow(metaSchema) {
      | msgMeta => Some(msgMeta.service)
      | exception err =>
        Js.log2("Message.serviceNameOfMsg: Couldn't parse meta:", err)
        None
      }
    )
  | None =>
    Js.log2("Message.serviceNameOfMsg: couldn't decodeObject:", msgJson)
    None
  }

let variantNameOfJson = json => {
  switch json->Js.Json.classify {
  | JSONString(str) => str
  | JSONObject(dict) =>
    switch dict->Js.Dict.get("TAG") {
    | Some(String(tag)) => tag
    | _ => "unknown"
    }
  | _ => "unknown"
  }
}

// TODO: group all functions on event`Json into submodule with the according type

let eventNameOfEvent'Json = json => {
  switch json->Js.Json.decodeObject {
  | Some(dict) => dict->Js.Dict.unsafeGet("event")->variantNameOfJson
  | _ => "unknownEventName"
  }
}

let idOfEvent'Json = json => {
  json
  ->Js.Json.decodeObject
  ->Option.flatMap(event' => event'->Js.Dict.unsafeGet("id")->Js.Json.decodeString)
}

let idMetaEventOfEvent'Json = json => {
  let dict = json->Js.Json.decodeObject
  let id =
    dict
    ->Option.flatMap(dict => dict->Dict.get("id")->Option.flatMap(id => id->Js.Json.decodeString))
    ->Option.getOr("unknownId")
  let meta =
    dict
    ->Option.flatMap(dict =>
      dict->Dict.get("meta")->Option.map(metaStr => metaStr->Js.Json.stringify)
    )
    ->Option.getOr("noMeta")
  let event =
    dict
    ->Option.flatMap(dict =>
      dict->Dict.get("event")->Option.map(eventStr => eventStr->Js.Json.stringify)
    )
    ->Option.getOr("noEvent")

  (id, meta, event)
}

type eventsHandler<'id, 'event> = (
  'id,
  array<ReventlessSpec.Message.event'<'id, 'event>>,
) => Js.Promise.t<unit>

module type Events = {
  type id
  type event
}

exception InvalidEvent(Js.Json.t)
exception InvalidCommand(Js.Json.t)

@val @scope("JSON") @deprecated("use Js.Json.stringify() or Js.Json.stringifyAny()")
external stringify: _ => string = "stringify"

type hrtime = (int, int)
@val @scope("process") external hrtime: unit => hrtime = "hrtime"

let hrtimeToString: (~hrtime: hrtime, ~now: float) => string = (~hrtime, ~now) => {
  let (_, mil) = hrtime
  let milString = mil->string_of_int
  let milLength = milString->String.length
  now->Js.Float.toString ++ ("-" ++ (String.repeat("0", 9 - milLength) ++ milString))
}

type errorHandler<'error, 'command, 'event> = (
  'error,
  'command,
  ReventlessSpec.Message.context,
) => array<'event>

let generateMeta = (~service, ~ip="", ~user="unknown") => {
  let msgId = uuid()
  {service, ip, user, time: nowAsISOString(), msgId, correlationId: msgId}
}

let decomposeMeta = meta =>
  meta
  ->S.reverseConvertToJsonOrThrow(metaSchema)
  ->Js.Json.decodeObject
  ->Js.Option.getExn
  ->Js.Dict.entries

let composeEventJson' = (id, meta, eventJson) =>
  [
    ("id", id->Js.Json.string),
    ("meta", meta->S.reverseConvertToJsonOrThrow(metaSchema)),
    ("event", eventJson),
  ]
  ->Js.Dict.fromArray
  ->Js.Json.object_

let string = x =>
  switch x {
  | Some(ip) if ip == Js.Json.null => ""->Js.Json.string
  | Some(ip) => ip
  | None => ""->Js.Json.string
  }

let composeMeta = (dict: dict<Js.Json.t>) =>
  [
    ("service", dict->Js.Dict.get("service")->Option.getExn),
    ("time", dict->Js.Dict.get("time")->Option.getExn),
    ("ip", dict->Js.Dict.get("ip")->string),
    ("user", dict->Js.Dict.get("user")->string),
    ("msgId", dict->Js.Dict.get("msgId")->Option.getExn),
    ("correlationId", dict->Js.Dict.get("correlationId")->Option.getExn),
  ]
  ->Js.Dict.fromArray
  ->Js.Json.object_

// type decoder<'a> = Js.Json.t => result<'a, Decco.decodeError>
// type encoder<'a> = 'a => Js.Json.t

let commandJsonOfCommand': (
  ~idToString: 'id => string,
  ~commandSchema: S.t<'command>,
  command'<'id, 'command>,
) => commandJson = (~idToString, ~commandSchema, cmd) => {
  {
    id: cmd.id->idToString,
    meta: cmd.meta,
    commandJson: cmd.command->encode(commandSchema),
    delay: None,
  }
}

let splitMessage = json =>
  switch json->Js.Json.decodeObject {
  | Some(dict) =>
    let (tags, payload) = dict->Dict.toArray->Belt.Array.partition(((key, _)) => key == "TAG")
    let typ = switch tags[0] {
    | Some((_, String(t))) => t
    | _ => "Unknown"
    }
    (typ, payload->Dict.fromArray)
  | _ => ("Unknown", Dict.make())
  }

let combineMessage = (typ, data) => {
  JSON.Object([("TAG", JSON.String(typ))]->Array.concat(data->Dict.toArray)->Dict.fromArray)
}
