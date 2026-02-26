module Id = Reventless.Id.String

@schema
type status =
  | Connected
  | Disconnected
  | Inactive

@schema
type state = {
  name: Reventless.Plugin.name,
  version: Reventless.Plugin.version,
  eventCollector: string,
  extensionPoints: array<Reventless.Plugin.extensionPointDefinition>,
  extensionPointNames: array<string>,
  extensionNames: array<string>,
  extensions: array<Reventless.Plugin.extensionDefinition>,
  status: status,
  statusChange: Message.statusChange,
}

type queryResult = {
  id: string,
  name: Reventless.Plugin.name,
  version: Reventless.Plugin.version,
  eventCollector: string,
  extensionPoints: array<Reventless.Plugin.extensionPointDefinition>,
  extensionPointNames: array<string>,
  extensionNames: array<string>,
  extensions: array<Reventless.Plugin.extensionDefinition>,
  status: status,
}

let name = "Plugin"

open Reventless.ReadModel
let config = config()
let subIdConfig = None
