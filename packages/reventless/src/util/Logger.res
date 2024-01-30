module Level = {
  type t =
    | Debug
    | Info
    | Warning
    | Error
    | Custom(string)

  let toString = level =>
    switch level {
    | Debug => "DEBUG"
    | Info => "INFO"
    | Warning => "WARNING"
    | Error => "ERROR"
    | Custom(x) => x
    }

  let default = Info
}

type logItem
external logItem: 'a => logItem = "%identity"
external identity: 'a => 'a = "%identity"

let log: (
  ~loc: string=?,
  ~map: 'a => 'b=?,
  ~stringify: bool=?,
  ~level: Level.t=?,
  string,
  'a,
) => unit = (~loc=?, ~map=identity, ~stringify=false, ~level=Level.default, desc, item) => {
  let tag =
    level->Level.toString ++ loc->Belt.Option.mapWithDefault(":", loc => "(" ++ (loc ++ "):"))

  let itemMapped = item->map

  // try to stringify, use raw value if unsuccessfull
  let (descStringified, itemStringified) = if stringify {
    let itemStringified = itemMapped->Js.Json.stringifyAny
    let descStringified =
      itemStringified->Belt.Option.mapWithDefault(
        desc ++ " [ERROR: Couldn't stringify, displaying raw value!]",
        _ => desc,
      )
    let itemStringifiedWithDefault =
      itemStringified->Belt.Option.mapWithDefault(itemMapped->logItem, i => i->logItem)
    (descStringified, itemStringifiedWithDefault)
  } else {
    (desc, itemMapped->logItem)
  }

  switch level {
  | Warning => Js.Console.warn3(tag, descStringified, itemStringified)
  | Error => Js.Console.error3(tag, descStringified, itemStringified)
  | Info
  | Custom(_) =>
    Js.Console.info3(tag, descStringified, itemStringified)

  | Debug => Js.Console.log3(tag, descStringified, itemStringified)
  }
}

let commandJsonsToLogMessages: array<Message.commandJson> => array<string> = cmds => {
  let count = cmds->Belt.Array.size->Belt.Int.toString
  cmds->Belt.Array.mapWithIndex((idx, {id, commandJson}) => {
    let idx = (idx + 1)->Belt.Int.toString
    let commandStringified = commandJson->Js.Json.stringify
    `${idx}/${count}: id=${id}, ${commandStringified}`
  })
}

// NOTE: maybe decompose this into 2 functions
//  - locCmdJson: single
//  - locCmdJsons: array
let logCmdJsons = (~loc=?, ~level=Level.Info, cmdJsons, desc) => {
  cmdJsons
  ->commandJsonsToLogMessages
  ->Belt.Array.forEach(msg => {
    log(~loc?, ~level, desc, msg)
  })
}

let event'JsonToLogMessage: Js.Json.t => option<string> = event'Json => {
  let id = event'Json->Message.idOfEvent'Json
  let eventName = event'Json->Message.eventNameOfEvent'Json
  let eventStringified = event'Json->Js.Json.stringify
  switch (id, eventName) {
  | (Some(id), Some(eventName)) => Some(`${eventName}(${id}) complete event: ${eventStringified}`)
  | _ => None
  }
}

let logEvent'Json = (~loc=?, ~level=Level.Info, event'Json, desc) => {
  event'JsonToLogMessage(event'Json)
  ->Belt.Option.getWithDefault(`Couldn't log event: ${event'Json->Js.Json.stringify}`)
  ->log(~loc?, ~level, desc, _)
}
