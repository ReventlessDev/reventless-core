@@reventless.spec("Plugins")

// Current view — one row per plugin **name**, holding the currently-active
// version's definition. Keyed by the aggregate id (= plugin name). The status
// here is the *current* version's status; "Superseded" is not represented (a
// superseded version is simply no longer the current row).
@schema
type status =
  | Connected
  | Disconnected
  // Admin suspend (Deactivate).
  | Inactive
  // Manual admin retirement (archive) of the current version.
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
  // Business role of the plugin (from pluginDefinition.kind). Lets the admin Plugins
  // view segregate PlatformInfrastructure / Commercial / Marketplace from Domain.
  // @scan opts the field into server-side equality filtering so the connection gains
  // a `kindEq` filter — the panel split (main list vs System/Infrastructure) pages
  // correctly server-side rather than filtering a page client-side.
  @scan kind: Reventless.Plugin.pluginKind,
  // Other versions of this name that are currently **Connected** — excludes this
  // row's own `version` (whose status is the `status` field above). Lets the
  // projection recompute which version is current (highest Connected) during a
  // deploy overlap, and is pruned the moment a version stops being Connected. So
  // it is empty in steady state and holds at most the one-or-two concurrently-live
  // versions of a rolling deploy — never the full history.
  otherConnectedVersions: array<Reventless.Plugin.version>,
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
  kind: Reventless.Plugin.pluginKind,
}


