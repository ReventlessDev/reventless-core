module type Service = {
  module Id: ReventlessSpec.Id.T;

  [@decco]
  type id = Id.t;

  [@decco]
  type command;
  [@decco]
  type event;
  [@decco]
  type error;

  let name: string;
};

include ReventlessSpec.Message;

let uuid = Uuid.v4;

let now = () => Js.Date.make()->Js.Date.getTime;

let nowAsISOString = () => Js.Date.make()->Js.Date.toISOString;

type handler('msg) = 'msg => Js.Promise.t(unit);

[@decco]
type command'('id, 'command) = {
  id: 'id,
  meta,
  command: 'command,
};

[@decco]
type commandJson = {
  id: string,
  meta,
  commandJson: Js.Json.t,
  delay: option(int),
};

let toMessageBody = ({id, meta, commandJson}) => {
  let commandMeta: meta = {...meta, msgId: uuid(), time: nowAsISOString()};
  [|
    ("id", id->Js.Json.string),
    ("meta", commandMeta->meta_encode),
    ("command", commandJson),
  |]
  ->Js.Dict.fromArray
  ->Js.Json.object_
  ->Js.Json.stringify;
};

type commandHandler('id, 'command) =
  (. command'('id, 'command)) => Js.Promise.t(unit);

type commandsHandler('id, 'command) =
  (. 'id, array(command'('id, 'command))) => Js.Promise.t(unit);

let serviceNameOfMsg = msgJson =>
  switch (msgJson->Js.Json.decodeObject) {
  | Some(msgObj) =>
    msgObj->Js.Dict.get("meta")->Belt.Option.map(meta_decode)
    |> (
      fun
      | Some(Ok(msgMeta)) => Some(msgMeta.service)
      | Some(Error(err)) => {
          Js.log2("Message.serviceNameOfMsg: Couldn't decode meta:", err);
          None;
        }
      | _ => {
          Js.log("Message.serviceNameOfMsg: Invalid JSON object");
          None;
        }
    )
  | None =>
    Js.log2("Message.serviceNameOfMsg:", msgJson);
    None;
  };

type eventsHandler('id, 'event) =
  (. 'id, array(ReventlessSpec.Message.event'('id, 'event))) =>
  Js.Promise.t(unit);

module type Events = {
  type id;
  type event;
};

exception InvalidEvent(Js.Json.t);
exception InvalidCommand(Js.Json.t);

[@bs.val]
[@bs.scope "JSON"]
[@deprecated "use Js.Json.stringify() or Js.Json.stringifyAny()"]
external stringify: Js.t(_) => string = "stringify";

let log: ('a, string) => 'a =
  (value, str) => {
    Js.log2(str, value);
    value;
  };

let logEvent'Json = (event'Json, description) => {
  let eventStr = event'Json->Js.Json.stringify;
  try (
    {
      let event' = event'Json->Js.Json.decodeObject->Belt.Option.getExn;
      let id = event'->Js.Dict.unsafeGet("id")->Js.Json.decodeString;
      let eventName =
        event'
        ->Js.Dict.unsafeGet("event")
        ->Js.Json.decodeArray
        ->Belt.Option.flatMap(evtArr => evtArr->Belt.Array.get(0))
        ->Belt.Option.flatMap(evt => evt->Js.Json.decodeString)
        ->Belt.Option.getExn;
      Js.log({j|$description $eventName($id) complete event: $eventStr|j});
    }
  ) {
  | _ => Js.log2("Couldn't log event:", eventStr)
  };
};

type hrtime = (int, int);
[@bs.val] [@bs.scope "process"] external hrtime: unit => hrtime = "hrtime";

let hrtimeToString: (~hrtime: hrtime, ~now: float) => string =
  (~hrtime, ~now) => {
    let (_, mil) = hrtime;
    let milString = mil->string_of_int;
    let milLength = milString->String.length;
    now->Js.Float.toString
    ++ "-"
    ++ String.make(9 - milLength, '0')
    ++ milString;
  };

type errorHandler('error, 'command, 'event) =
  ('error, 'command, ReventlessSpec.Message.context) => list('event);

let generateMeta = (~service, ~ip="", ~user="unknown", ()) => {
  let msgId = uuid();
  {service, ip, user, time: nowAsISOString(), msgId, correlationId: msgId};
};

let decomposeMeta = meta =>
  meta->meta_encode->Js.Json.decodeObject->Js.Option.getExn->Js.Dict.entries;

let string =
  fun
  | Some(ip) when ip == Js.Json.null => ""->Js.Json.string
  | Some(ip) => ip
  | None => ""->Js.Json.string;

let composeMeta = (dict: Js.Dict.t(Js.Json.t)) =>
  [|
    ("service", dict->Js.Dict.get("service")->Belt.Option.getExn),
    ("time", dict->Js.Dict.get("time")->Belt.Option.getExn),
    ("ip", dict->Js.Dict.get("ip")->string),
    ("user", dict->Js.Dict.get("user")->string),
    ("msgId", dict->Js.Dict.get("msgId")->Belt.Option.getExn),
    (
      "correlationId",
      dict->Js.Dict.get("correlationId")->Belt.Option.getExn,
    ),
  |]
  ->Js.Dict.fromArray
  ->Js.Json.object_;

type decoder('a) = Js.Json.t => Belt.Result.t('a, Decco.decodeError);
type encoder('a) = 'a => Js.Json.t;
