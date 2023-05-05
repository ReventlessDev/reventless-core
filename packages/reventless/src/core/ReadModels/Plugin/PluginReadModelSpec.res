module Id = ReventlessSpec.Id.String

@decco
type status =
  | Connected
  | Disconnected
  | Inactive

@decco
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

open ReventlessSpec.ReadModel.Spec
let resolveIdConfigs: array<resolveIdConfig> = []
let resolveIdsConfigs: array<resolveIdsConfig> = []

let subIdConfig = None

let indexes: array<index> = []
