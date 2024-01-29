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

module Json = {
  let variantName: Js.Json.t => option<string> = json =>
    json
    ->Js.Json.decodeArray
    ->Belt.Option.flatMap(evtArr => evtArr->Belt.Array.get(0))
    ->Belt.Option.flatMap(evt => evt->Js.Json.decodeString)
}

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

let logCmdJsons = (cmdJsons, desc) => {
  let count = cmdJsons->Belt.Array.size
  cmdJsons->Belt.Array.forEachWithIndex((idx, {Message.id: id, commandJson}) => {
    let idx = idx + 1
    let messageBody = commandJson->Js.Json.stringify
    Js.log(
      `${desc} ${idx->Belt.Int.toString}/${count->Belt.Int.toString}: id=${id}, ${messageBody}`,
    )
  })
}

let logEvent'Json = (event'Json, description) => {
  let eventStr = event'Json->Js.Json.stringify
  try {
    let event' = event'Json->Js.Json.decodeObject->Belt.Option.getExn
    let id =
      event'
      ->Js.Dict.unsafeGet("id")
      ->Js.Json.decodeString
      ->Belt.Option.getWithDefault("{ERROR (" ++ __LOC__ ++ "): Could not get id!}")
    let eventName = event'->Js.Dict.unsafeGet("event")->Json.variantName->Belt.Option.getExn
    Js.log(`${description} ${eventName}(${id}) complete event: ${eventStr}`)
  } catch {
  | _ => Js.log2("Couldn't log event:", eventStr)
  }
}
