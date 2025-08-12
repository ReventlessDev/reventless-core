module Id = ReventlessSpec.Id.String

@schema
type status =
  | Connected
  | Disconnected
  | Inactive

@schema
type state = {
  name: ReventlessSpec.Plugin.name,
  version: ReventlessSpec.Plugin.version,
  eventCollector: string,
  extensionPoints: array<ReventlessSpec.Plugin.extensionPointDefinition>,
  extensionPointNames: array<string>,
  extensionNames: array<string>,
  extensions: array<ReventlessSpec.Plugin.extensionDefinition>,
  status: status,
  statusChange: Message.statusChange,
}

type queryResult = {
  id: string,
  name: ReventlessSpec.Plugin.name,
  version: ReventlessSpec.Plugin.version,
  eventCollector: string,
  extensionPoints: array<ReventlessSpec.Plugin.extensionPointDefinition>,
  extensionPointNames: array<string>,
  extensionNames: array<string>,
  extensions: array<ReventlessSpec.Plugin.extensionDefinition>,
  status: status,
}

let name = "Plugin"

open ReventlessSpec.ReadModel_Spec
let config = config()
let subIdConfig = None
