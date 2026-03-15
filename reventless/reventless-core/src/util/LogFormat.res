// Log formatting utilities for domain objects.

let commandJsonToLogMessage: Message.commandJson => string = ({id, meta, commandJson}) => {
  let commandName = commandJson->Message.variantNameOfJson
  let commandStr = commandJson->JSON.stringify
  let metaStr = meta->Message.encode(Message.metaSchema)->JSON.stringify
  `${commandName}(${id}): {"command":${commandStr},"meta":${metaStr},"id":"${id}"}`
}
let commandJsonsToLogMessages: array<Message.commandJson> => array<string> = cmdJsons => {
  let count = cmdJsons->Array.length->Int.toString
  cmdJsons->Array.mapWithIndex((cmdJson, idx) => {
    let idx = (idx + 1)->Int.toString
    `${idx}/${count}: ${cmdJson->commandJsonToLogMessage}`
  })
}

let event'JsonToLogMessage = event'Json => {
  let eventName = event'Json->Message.eventNameOfEvent'Json
  let (id, metaStr, eventStr) = event'Json->Message.idMetaEventOfEvent'Json
  let event'Str = `{"event":${eventStr},"meta":${metaStr},"id":"${id}"}`
  `${eventName}(${id}): ${event'Str}`
}
