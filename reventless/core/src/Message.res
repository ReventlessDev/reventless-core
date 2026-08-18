let logger = Logger.fromEnv()

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

// Compose the wrapper schema once per (idSchema, payloadSchema) reference pair.
// Both are module-level constants per message type, and sury schemas are built
// to be reused across many parse/serialize calls — so the previous fresh
// `S.object` on every decode/encode was pure allocation on the hottest path in
// the framework. The cache is keyed by object identity (nested WeakMaps), so a
// dropped schema is still collectable. `build` runs only on a miss.
//
// The raw closure is typed monomorphically over an opaque type (concrete → no
// weak-var value-restriction problem); the locally-abstract-typed wrapper below
// is a syntactic function, so it generalizes and `Obj.magic` bridges the two.
// This keeps the public `toEventSchema'` / `toCommandSchema'` fully polymorphic.
type opaqueSchema
let _rawMemoize: (
  opaqueSchema,
  opaqueSchema,
  (opaqueSchema, opaqueSchema) => opaqueSchema,
) => opaqueSchema = %raw(`(function(){
  const outer = new WeakMap();
  return function(a, b, build){
    let inner = outer.get(a);
    if (inner === undefined) { inner = new WeakMap(); outer.set(a, inner); }
    let v = inner.get(b);
    if (v === undefined) { v = build(a, b); inner.set(b, v); }
    return v;
  };
})()`)
let memoizeBySchemaPair = (type a b c, a: a, b: b, build: (a, b) => c): c =>
  _rawMemoize(Obj.magic(a), Obj.magic(b), Obj.magic(build))->Obj.magic

let toEventSchema' = (idSchema, eventSchema) =>
  memoizeBySchemaPair(idSchema, eventSchema, (idSchema, eventSchema) =>
    S.object(s => {
      id: s.field("id", idSchema),
      meta: s.field("meta", metaSchema),
      event: s.field("event", eventSchema),
    })
  )
let toCommandSchema' = (idSchema, commandSchema) =>
  memoizeBySchemaPair(idSchema, commandSchema, (idSchema, commandSchema) =>
    S.object(s => {
      id: s.field("id", idSchema),
      meta: s.field("meta", metaSchema),
      command: s.field("command", commandSchema),
    })
  )

// Schema-migration-on-read: reuse the tolerant parse from `Reventless.Message`
// (`parseJsonTolerant` / `fillMissingDefaults`, included above) so a message persisted
// before a nested `@schema` field existed still decodes instead of bricking the
// aggregate's log replay. These two entry points thread the memoized envelope schema;
// `Reventless.Message.decode` (the other central decoder) is tolerant at the source.
// See docs/plans/done/platform-infrastructure-in-plugin-list.md (durable fix option 2).
let decodeEvent' = (json, idSchema, eventSchema) =>
  json->parseJsonTolerant(toEventSchema'(idSchema, eventSchema))
let decodeCommand' = (json, idSchema, commandSchema) =>
  json->parseJsonTolerant(toCommandSchema'(idSchema, commandSchema))

let encodeEvent' = (event', idSchema, eventSchema) =>
  event'->Reventless.Util_Sury.toJson(toEventSchema'(idSchema, eventSchema))
let encodeCommand' = (command', idSchema, commandSchema) =>
  command'->Reventless.Util_Sury.toJson(toCommandSchema'(idSchema, commandSchema))

let uuid = Uuid.v4

let log: ('a, string) => 'a = (value, str) => {
  logger.debug(~comp="Message", ~data=value->JSON.stringifyAny->Option.getOr("")->JSON.Encode.string, str)
  value
}

let now = () => Date.make()->Date.getTime

let nowAsISOString = () => Date.make()->Date.toISOString

let toMessageBody = ({id, meta, commandJson}) => {
  let commandMeta: meta = {...meta, msgId: uuid(), time: nowAsISOString()}
  [
    ("id", id->JSON.Encode.string),
    ("meta", commandMeta->Reventless.Util_Sury.toJson(metaSchema)),
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
      switch meta->Reventless.Util_Sury.fromJson(metaSchema) {
      | msgMeta => Some(msgMeta.service)
      | exception err =>
        logger.warn(
          ~comp="Message",
          ~data=err->JSON.stringifyAny->Option.getOr("")->JSON.Encode.string,
          "serviceNameOfMsg: Couldn't parse meta",
        )
        None
      }
    )
  | None =>
    logger.warn(~comp="Message", ~data=msgJson, "serviceNameOfMsg: couldn't decodeObject")
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
@val @scope("process") @deprecated("No longer used — sequenceNr is now an integer counter")
external hrtime: unit => hrtime = "hrtime"

@deprecated("No longer used — sequenceNr is now an integer counter")
let hrtimeToString: (~hrtime: hrtime, ~now: float) => string = (~hrtime, ~now) => {
  let (_, mil) = hrtime
  let milString = mil->Int.toString
  let milLength = milString->String.length
  now->Float.toString ++ ("-" ++ (String.repeat("0", 9 - milLength) ++ milString))
}


let generateMeta = (
  ~service,
  ~ip=?,
  ~user=?,
  ~causationId=?,
  ~traceparent=?,
  ~correlationId=?,
  ~schemaVersion=?,
  ~headers=?,
) => {
  let msgId = uuid()
  {
    service,
    time: nowAsISOString(),
    msgId,
    correlationId: correlationId->Option.getOr(msgId),
    ip: ?ip,
    user: ?user,
    causationId: ?causationId,
    traceparent: ?traceparent,
    schemaVersion: ?schemaVersion,
    headers: ?headers,
  }
}

// Derive a child message's meta from a triggering parent message:
//   - fresh `msgId` and `time`
//   - `correlationId` inherited (so the chain root id stays stable)
//   - `causationId` = parent.msgId (the *direct* parent)
//   - `ip`, `user`, `traceparent`, `schemaVersion`, `headers` inherited as-is
//   - `service` overridable; defaults to parent's service
let deriveMeta = (~parent: meta, ~service=?) => {
  service: service->Option.getOr(parent.service),
  time: nowAsISOString(),
  msgId: uuid(),
  correlationId: parent.correlationId,
  causationId: parent.msgId,
  ip: ?parent.ip,
  user: ?parent.user,
  traceparent: ?parent.traceparent,
  schemaVersion: ?parent.schemaVersion,
  headers: ?parent.headers,
}

let decomposeMeta = meta =>
  meta
  ->Reventless.Util_Sury.toJson(metaSchema)
  ->JSON.Decode.object
  ->Option.getOrThrow
  ->Dict.toArray

let composeEventJson' = (id, meta, ~recordedAt, eventJson) =>
  [
    ("id", id->JSON.Encode.string),
    ("meta", meta->Reventless.Util_Sury.toJson(metaSchema)),
    ("recordedAt", recordedAt->JSON.Encode.string),
    ("event", eventJson),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object

// Build a meta JSON object from a flat dict (e.g. one whose top-level keys are
// the meta.* attributes of a DynamoDB item). Required keys must be present;
// optional keys are passed through when present and omitted when absent.
let composeMeta = (dict: dict<JSON.t>) => {
  let out = [
    ("service", dict->Dict.get("service")->Option.getOrThrow),
    ("time", dict->Dict.get("time")->Option.getOrThrow),
    ("msgId", dict->Dict.get("msgId")->Option.getOrThrow),
    ("correlationId", dict->Dict.get("correlationId")->Option.getOrThrow),
  ]
  let optionalKeys = ["ip", "user", "causationId", "traceparent", "schemaVersion", "headers"]
  let optional =
    optionalKeys
    ->Array.map(k => dict->Dict.get(k)->Option.map(v => (k, v)))
    ->Array.filterMap(x => x)
  out->Array.concat(optional)->Dict.fromArray->JSON.Encode.object
}

// The set of keys that belong to `meta`. Used by `flatJsonToStoredEvent` to
// separate meta keys from envelope keys when reading flat on-disk items.
let metaKeys = [
  "service",
  "time",
  "ip",
  "user",
  "msgId",
  "correlationId",
  "causationId",
  "traceparent",
  "schemaVersion",
  "headers",
]

/*
  StoredEvent ↔ flat on-disk JSON helpers.

  `StoredEvent` is the logical shape (nested `meta:meta`). The on-disk shape is
  a flat top-level dict so DynamoDB GSIs can project individual meta attributes
  (the §1.2/§3.2 behaviour today, preserved here). These two helpers are the
  single bridge between the two — used by both EventLog (aggregate) and
  DcbEventLog (DCB) storage paths.
*/

/** Encode a typed `StoredEvent` to the flat on-disk JSON shape. */
let storedEventToFlatJson = (
  stored: Reventless.StoredEvent.storedEvent<'id>,
  idSchema: S.t<'id>,
): JSON.t => {
  let fields = [
    ("id", stored.id->Reventless.Util_Sury.toJson(idSchema)),
    ("position", JSON.String(stored.position)),
    ("event", JSON.String(stored.event)),
    ("data", stored.data),
    ("recordedAt", JSON.String(stored.recordedAt)),
  ]
  let withTags = switch stored.tags {
  | Some(tags) =>
    let tagsJson = tags->Reventless.Util_Sury.toJson(S.array(Reventless.DcbTag.tagSchema))
    fields->Array.concat([("tags", tagsJson)])
  | None => fields
  }
  withTags->Array.concat(stored.meta->decomposeMeta)->Dict.fromArray->JSON.Encode.object
}

/** Decode the flat on-disk JSON shape into a typed `StoredEvent`. */
let flatJsonToStoredEvent = (
  json: JSON.t,
  idSchema: S.t<'id>,
): Reventless.StoredEvent.storedEvent<'id> => {
  let dict = json->JSON.Decode.object->Option.getOrThrow
  let id = dict->Dict.get("id")->Option.getOrThrow->Reventless.Util_Sury.fromJson(idSchema)
  let position = dict->Dict.get("position")->Option.getOrThrow->JSON.Decode.string->Option.getOrThrow
  let event = dict->Dict.get("event")->Option.getOrThrow->JSON.Decode.string->Option.getOrThrow
  let data = dict->Dict.get("data")->Option.getOrThrow
  let recordedAt =
    dict->Dict.get("recordedAt")->Option.getOrThrow->JSON.Decode.string->Option.getOrThrow
  let meta = composeMeta(dict)->Reventless.Util_Sury.fromJson(metaSchema)
  let tags =
    dict
    ->Dict.get("tags")
    ->Option.map(t => t->Reventless.Util_Sury.fromJson(S.array(Reventless.DcbTag.tagSchema)))
  {id, position, event, data, recordedAt, meta, tags: ?tags}
}

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
    let (tags, payload) = dict->Dict.toArray->Array.partition(((key, _)) => key == "TAG")
    let typ = switch tags[0] {
    | Some((_, String(t))) => t
    | _ => "Unknown"
    }
    (typ, payload->Dict.fromArray)
  | _ =>
    // Payload-less variants: sury encodes as a bare JSON string
    switch json->JSON.Decode.string {
    | Some(t) => (t, Dict.make())
    | _ => ("Unknown", Dict.make())
    }
  }

let combineMessage = (typ, data) => {
  if Dict.toArray(data)->Array.length == 0 {
    // Payload-less variant: sury expects a bare JSON string
    JSON.String(typ)
  } else {
    JSON.Object([("TAG", JSON.String(typ))]->Array.concat(data->Dict.toArray)->Dict.fromArray)
  }
}
