@@reventless.spec("Plugin")

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
  apiSchemaFragment: @s.matches(Reventless.Plugin.apiSchemaFragmentOptionSchema) option<Reventless.Plugin.apiSchemaFragment>,
  // API target for split-API schema routing. Absent/None means "Domain" (backward compat).
  // "Platform" → excluded from DomainApi runtime schema stitching in updateApiSchema.
  apiTarget?: string,
  uiFragments: @s.matches(Reventless.Plugin.uiFragmentManifestOptionSchema) option<Reventless.Plugin.uiFragmentManifest>,
  // Plugin structure (component metadata) — surfaced via Platform_UIDefinitions.
  // None for older plugins whose protocol version did not carry the field.
  structure: @s.matches(Reventless.Plugin.pluginStructureOptionSchema) option<Reventless.Plugin.pluginStructure>,
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
  apiSchemaFragment: option<Reventless.Plugin.apiSchemaFragment>,
  apiTarget?: string,
  uiFragments: option<Reventless.Plugin.uiFragmentManifest>,
  structure: option<Reventless.Plugin.pluginStructure>,
}


