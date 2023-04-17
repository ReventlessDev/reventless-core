module Id = Id.String

open PluginSpec

@decco
type status =
  | Connected
  | Disconnected
  | Inactive

@decco
type state = {
  name: name,
  version: version,
  eventCollector: string,
  extensionPoints: array<extensionPointDefinition>,
  extensionPointNames: array<string>,
  extensionNames: array<string>,
  extensions: array<extensionDefinition>,
  status: status,
  statusChange: Message.statusChange,
}

type queryResult = {
  id: string,
  name: name,
  version: version,
  eventCollector: string,
  extensionPoints: array<extensionPointDefinition>,
  extensionPointNames: array<string>,
  extensionNames: array<string>,
  extensions: array<extensionDefinition>,
  status: status,
}

let name = "Plugin"

let resolveIdConfigs = list{}
let resolveIdsConfigs = list{}

let subIdConfig = None

let indexes = list{}
