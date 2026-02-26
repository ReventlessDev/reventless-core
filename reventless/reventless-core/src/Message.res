module type Service = {
  module Id: Reventless.Id.T

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

include Reventless.Message

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
  Console.log2(str, value)
  value
}

let now = () => Date.make()->Date.getTime

let nowAsISOString = () => Date.make()->Date.toISOString

let toMessageBody = ({id, meta, commandJson}) => {
  let commandMeta: meta = {...meta, msgId: uuid(), time: nowAsISOString()}
  [
    ("id", id->JSON.Encode.string),
    ("meta", commandMeta->S.reverseConvertToJsonOrThrow(metaSchema)),
    ("command", commandJson),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object
  ->JSON.stringify
}

type commandHandler<'id, 'command> = command'<'id, 'command> => promise<unit>

type commandsHandler<'id, 'command> = ('id, array<command'<'id, 'command>>) => promise<unit>

type handler<'msg> = 'msg => promise<unit>

let serviceNameOfMsg = msgJson =>
  switch msgJson->JSON.Decode.object {
  | Some(msgObj) =>
    msgObj
    ->Dict.get("meta")
    ->Option.flatMap(meta =>
      switch meta->S.parseJsonOrThrow(metaSchema) {
      | msgMeta => Some(msgMeta.service)
      | exception err =>
        Console.log2("Message.serviceNameOfMsg: Couldn't parse meta:", err)
        None
      }
    )
  | None =>
    Console.log2("Message.serviceNameOfMsg: couldn't decodeObject:", msgJson)
    None
  }

let variantNameOfJson = json => {
  switch json {
  | JSON.String(str) => str
  | Object(dict) =>
    switch dict->Dict.get("TAG") {
    | Some(String(tag)) => tag
    | _ => "unknown"
    }
  | _ => "unknown"
  }
}

// TODO: group all functions on event`Json into submodule with the according type

let eventNameOfEvent'Json = json => {
  switch json->JSON.Decode.object {
  | Some(dict) => dict->Dict.getUnsafe("event")->variantNameOfJson
  | _ => "unknownEventName"
  }
}

let idOfEvent'Json = json => {
  json
  ->JSON.Decode.object
  ->Option.flatMap(event' => event'->Dict.getUnsafe("id")->JSON.Decode.string)
}

let idMetaEventOfEvent'Json = json => {
  let dict = json->JSON.Decode.object
  let id =
    dict
    ->Option.flatMap(dict => dict->Dict.get("id")->Option.flatMap(id => id->JSON.Decode.string))
    ->Option.getOr("unknownId")
  let meta =
    dict
    ->Option.flatMap(dict => dict->Dict.get("meta")->Option.map(metaStr => metaStr->JSON.stringify))
    ->Option.getOr("noMeta")
  let event =
    dict
    ->Option.flatMap(dict =>
      dict->Dict.get("event")->Option.map(eventStr => eventStr->JSON.stringify)
    )
    ->Option.getOr("noEvent")

  (id, meta, event)
}

type eventsHandler<'id, 'event> = (
  'id,
  array<Reventless.Message.event'<'id, 'event>>,
) => promise<unit>

module type Events = {
  type id
  type event
}

exception InvalidCommand(JSON.t)

@val @scope("JSON") @deprecated("use JSON.stringify() or JSON.stringifyAny()")
external stringify: _ => string = "stringify"

type hrtime = (int, int)
@val @scope("process") external hrtime: unit => hrtime = "hrtime"

let hrtimeToString: (~hrtime: hrtime, ~now: float) => string = (~hrtime, ~now) => {
  let (_, mil) = hrtime
  let milString = mil->Int.toString
  let milLength = milString->String.length
  now->Float.toString ++ ("-" ++ (String.repeat("0", 9 - milLength) ++ milString))
}

type errorHandler<'error, 'command, 'event> = (
  'error,
  'command,
  Reventless.Message.context,
) => array<'event>

let generateMeta = (~service, ~ip="", ~user="unknown") => {
  let msgId = uuid()
  {service, ip, user, time: nowAsISOString(), msgId, correlationId: msgId}
}

let decomposeMeta = meta =>
  meta
  ->S.reverseConvertToJsonOrThrow(metaSchema)
  ->JSON.Decode.object
  ->Option.getOrThrow
  ->Dict.toArray

let composeEventJson' = (id, meta, eventJson) =>
  [
    ("id", id->JSON.Encode.string),
    ("meta", meta->S.reverseConvertToJsonOrThrow(metaSchema)),
    ("event", eventJson),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object

let string = x =>
  switch x {
  | Some(ip) if ip == JSON.Encode.null => ""->JSON.Encode.string
  | Some(ip) => ip
  | None => ""->JSON.Encode.string
  }

let composeMeta = (dict: dict<JSON.t>) =>
  [
    ("service", dict->Dict.get("service")->Option.getOrThrow),
    ("time", dict->Dict.get("time")->Option.getOrThrow),
    ("ip", dict->Dict.get("ip")->string),
    ("user", dict->Dict.get("user")->string),
    ("msgId", dict->Dict.get("msgId")->Option.getOrThrow),
    ("correlationId", dict->Dict.get("correlationId")->Option.getOrThrow),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object

// type decoder<'a> = JSON.t => result<'a, Decco.decodeError>
// type encoder<'a> = 'a => JSON.t

let commandJsonOfCommand': (
  ~idToString: 'id => string,
  ~commandSchema: S.t<'command>,
  command'<'id, 'command>,
) => commandJson = (~idToString, ~commandSchema, cmd) => {
  {
    id: cmd.id->idToString,
    meta: cmd.meta,
    commandJson: cmd.command->encode(commandSchema),
  }
}

let splitMessage = json =>
  switch json->JSON.Decode.object {
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
