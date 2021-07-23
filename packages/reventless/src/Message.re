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

[@decco]
type statusChange = {
  at: string,
  by: string,
};

type handler('msg) = 'msg => Js.Promise.t(unit);

[@decco]
type command'('id, 'command) = {
  id: 'id,
  meta,
  command: 'command,
};

type commandHandler('id, 'command) =
  (. command'('id, 'command)) => Js.Promise.t(unit);

type commandsHandler('id, 'command) =
  (. 'id, array(command'('id, 'command))) => Js.Promise.t(unit);

[@decco]
type event'('id, 'event) = {
  id: 'id,
  meta,
  event: 'event,
};

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
  (. 'id, array(event'('id, 'event))) => Js.Promise.t(unit);

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
      let event: array(string) =
        event'->Js.Dict.unsafeGet("event")->Obj.magic;
      let eventName = event[0];
      Js.log({j|$description $eventName($id) complete event: $eventStr|j});
    }
  ) {
  | _ => Js.log2("Couldn't log event:", eventStr)
  };
};

let uuid = Uuid.v4;

let now = () => Js.Date.make()->Js.Date.getTime;

let nowAsISOString = () => Js.Date.make()->Js.Date.toISOString;

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

type context = {
  id: string,
  meta,
};

type errorHandler('error, 'command, 'event) =
  ('error, 'command, context) => list('event);

let generateMeta = (~service, ~ip="", ~user="", ()) => {
  let msgId = uuid();
  {service, ip, user, time: nowAsISOString(), msgId, correlationId: msgId};
};

type decoder('a) = Js.Json.t => Belt.Result.t('a, Decco.decodeError);
type encoder('a) = 'a => Js.Json.t;
