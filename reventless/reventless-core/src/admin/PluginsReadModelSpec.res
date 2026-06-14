@@reventless.spec("Plugins")

@schema
type status =
  | Connected
  | Disconnected
  | Inactive
  // Deploy-driven supersession by a newer version of the same plugin.
  // Distinct from Inactive (admin suspend): hidden from the manifest like
  // Inactive, but revivable only by the version's own Heartbeat.
  | Retired

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
  // Plugin structure (component metadata) — surfaced via Platform_ComponentDefinitions.
  // None for older plugins whose protocol version did not carry the field.
  structure: @s.matches(Reventless.Plugin.pluginStructureOptionSchema) option<Reventless.Plugin.pluginStructure>,
  // DCB EventLog definition for plugins that bundle a DcbEventLog component.
  // Admin's manageSubscriptions uses this to wire cross-plugin SNS subscriptions
  // from this plugin's DCB topic → peer EventCollectors (and vice-versa). None
  // for pure-aggregate plugins or for plugins persisted before Phase 4.
  dcbEventLog: @s.matches(Reventless.Plugin.dcbEventLogOptionSchema) option<Reventless.Plugin.dcbEventLogDefinition>,
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
  dcbEventLog: option<Reventless.Plugin.dcbEventLogDefinition>,
}


