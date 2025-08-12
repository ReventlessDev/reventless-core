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

let createTag = (~level as _, ~loc) => {
  let re = %re("/File \"(.*).res\", line (.*), characters (.*)-(.*)/")
  switch Js.Re.exec_(re, loc->Option.getOr("")) {
  | Some(result) =>
    let captures =
      result
      ->Js.Re.captures
      ->Array.map(capture => capture->Js.Nullable.toOption)
      ->Array.map(Option.getOr(_, ""))
    `${captures->Array.getUnsafe(1)}#${captures->Array.getUnsafe(2)}:`
  | _ => ""
  }
}

let log: (
  ~loc: string=?,
  ~map: 'a => 'b=?, // NOTE: potentially remove this arg
  ~stringify: bool=?,
  ~level: Level.t=?,
  string,
  'a,
) => unit = (~loc=?, ~map=identity, ~stringify=false, ~level=Level.default, desc, item) => {
  let tag = createTag(~level, ~loc)

  let itemMapped = item->map

  // try to stringify, use raw value if unsuccessfull
  let (descStr, itemStr) = if stringify {
    let itemStr = itemMapped->Js.Json.stringifyAny
    let descStringified =
      itemStr->Option.mapOr(desc ++ " [ERROR: Couldn't stringify, displaying raw value!]", _ =>
        desc
      )
    let itemStrWithDefault = itemStr->Option.mapOr(itemMapped->logItem, i => i->logItem)
    (descStringified, itemStrWithDefault)
  } else {
    (desc, itemMapped->logItem)
  }

  switch level {
  | Warning => Js.Console.warn3(tag, descStr, itemStr)
  | Error => Js.Console.error3(tag, descStr, itemStr)
  | Info
  | Custom(_) =>
    Js.Console.info3(tag, descStr, itemStr)
  | Debug => /*
        TODO: use js `console.debug`, when lambda FunctionLoggingConf setting has been incorporated into reventless-aws
        previously: Js.Console.info3(tag, descStringified, itemStr)
 */
    () // NOTE: noop for the time being to prevent consumption into CloudWatch logs
  }
}

let warn = log(~level=Level.Warning, ...)
let error = log(~level=Level.Error, ...)
let info = log(~level=Level.Info, ...)
let debug = log(~level=Level.Debug, ...)

let commandJsonToLogMessage: Message.commandJson => string = ({id, meta, commandJson}) => {
  let commandName = commandJson->Message.variantNameOfJson
  let commandStr = commandJson->Js.Json.stringify
  let metaStr = meta->Message.encode(Message.metaSchema)->Js.Json.stringify
  `${commandName}(${id}): {"command":${commandStr},"meta":${metaStr},"id":${id}}`
}
let commandJsonsToLogMessages: array<Message.commandJson> => array<string> = cmds => {
  let count = cmds->Array.length->Int.toString
  cmds->Array.mapWithIndex((cmd, idx) => {
    let idx = (idx + 1)->Int.toString
    `${idx}/${count}: ${cmd->commandJsonToLogMessage}`
  })
}

let logCmdJson = (~loc=?, ~level=Level.Info, cmdJson, desc) =>
  log(~loc?, ~level, desc, cmdJson->commandJsonToLogMessage)

let logCmdJsons = (~loc=?, ~level=Level.Info, cmdJsons, desc) => {
  cmdJsons
  ->commandJsonsToLogMessages
  ->Array.forEach(msg => {
    log(~loc?, ~level, desc, msg)
  })
}

let event'JsonToLogMessage = eventJson' => {
  let eventName = eventJson'->Message.eventNameOfEvent'Json
  let (id, metaStr, eventStr) = eventJson'->Message.idMetaEventOfEvent'Json
  let event'Str = `{"event":${eventStr},"meta":${metaStr},"id":"${id}"}`
  `${eventName}(${id}): ${event'Str}`
}

let logJsonEvent = (~loc=?, ~level=Level.Info, eventJson', desc) => {
  event'JsonToLogMessage(eventJson')->(log(~loc?, ~level, desc, _))
}
