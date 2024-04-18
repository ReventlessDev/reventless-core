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
  switch Js.Re.exec_(re, loc->Belt.Option.getWithDefault("")) {
  | Some(result) =>
    let captures =
      result
      ->Js.Re.captures
      ->Belt.Array.map(Js.Nullable.toOption)
      ->Belt.Array.map(Belt.Option.getWithDefault(_, ""))
    `${captures[1]}#${captures[2]}:`
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
      itemStr->Belt.Option.mapWithDefault(
        desc ++ " [ERROR: Couldn't stringify, displaying raw value!]",
        _ => desc,
      )
    let itemStrWithDefault =
      itemStr->Belt.Option.mapWithDefault(itemMapped->logItem, i => i->logItem)
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

let warn = log(~level=Level.Warning)
let error = log(~level=Level.Error)
let info = log(~level=Level.Info)
let debug = log(~level=Level.Debug)

let commandJsonToLogMessage: Message.commandJson => string = ({id, meta, commandJson}) => {
  let commandName = commandJson->Message.variantNameOfJson
  let commandStr = commandJson->Js.Json.stringify
  let metaStr = meta->ReventlessSpec.Message.meta_encode->Js.Json.stringify
  `${commandName}(${id}): {"command":${commandStr},"meta":${metaStr},"id":${id}}`
}
let commandJsonsToLogMessages: array<Message.commandJson> => array<string> = cmds => {
  let count = cmds->Belt.Array.size->Belt.Int.toString
  cmds->Belt.Array.mapWithIndex((idx, cmd) => {
    let idx = (idx + 1)->Belt.Int.toString
    `${idx}/${count}: ${cmd->commandJsonToLogMessage}`
  })
}

let logCmdJson = (~loc=?, ~level=Level.Info, cmdJson, desc) =>
  log(~loc?, ~level, desc, cmdJson->commandJsonToLogMessage)

let logCmdJsons = (~loc=?, ~level=Level.Info, cmdJsons, desc) => {
  cmdJsons
  ->commandJsonsToLogMessages
  ->Belt.Array.forEach(msg => {
    log(~loc?, ~level, desc, msg)
  })
}

let event'JsonToLogMessage = event'Json => {
  let eventName = event'Json->Message.eventNameOfEvent'Json
  let (id, metaStr, eventStr) = event'Json->Message.idMetaEventOfEvent'Json
  let event'Str = `{"event":${eventStr},"meta":${metaStr},"id":"${id}"}`
  `${eventName}(${id}): ${event'Str}`
}

let logEvent'Json = (~loc=?, ~level=Level.Info, event'Json, desc) => {
  event'JsonToLogMessage(event'Json)->log(~loc?, ~level, desc, _)
}
