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
  // Stored as the **untagged** offload wire JSON (a bare fragment, or an
  // `{$offload: {...}}` reference) — NOT the `Offload.payload` variant. The QueryDb
  // write path marshals the raw ReScript value straight to DynamoDB without
  // sury-encoding through this field's schema, so a variant would persist as its
  // runtime `{TAG, _0}` shape and no reader could parse it. UI-excluded
  // (PluginBaseFragment.pluginUIOnlyExcludeFields), so JSON.t typing costs no
  // GraphQL consumer. PluginsProjection.displayState writes it via Offload.toJson.
  apiSchemaFragment: option<JSON.t>,
  // API target for split-API schema routing. Absent/None means "Domain" (backward compat).
  // "Platform" → excluded from DomainApi runtime schema stitching in updateApiSchema.
  apiTarget?: string,
  // Plugin structure (component metadata) — surfaced via Platform_ComponentDefinitions.
  // None for older plugins whose protocol version did not carry the field. Same
  // untagged-JSON storage as apiSchemaFragment above; the ComponentDefinitions
  // Lambda detects the `$offload` sentinel and resolves it from S3.
  structure: option<JSON.t>,
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
  // @groupBy tags this field as the list view's section key (emitted as
  // `x-reventless-group-by`); AutoUI sections the admin Plugins view by kind.
  //
  // **Nullable on purpose.** Rows projected before `kind` existed carry no `kind`
  // attribute, and the deploy-time RedetectPlugin backfill only stamps a row on the
  // owning plugin's next deploy. A non-null `PluginKind!` would make GraphQL null the
  // entire `Platform_Plugins` query the moment a single kind-less row is returned
  // (existing rows, a newly-connecting plugin before it's stamped, or an internal
  // bookkeeping row). Optional here → nullable `Platform_PluginKind` in the SDL, so a
  // blank kind degrades to a missing group (AutoListView's trailing group) instead of
  // taking down the whole list. Backfill then upgrades blanks to real kinds.
  @scan @groupBy kind: option<Reventless.Plugin.pluginKind>,
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
  apiSchemaFragment: option<JSON.t>,
  apiTarget?: string,
  structure: option<JSON.t>,
  dcbEventLog: option<Reventless.Plugin.dcbEventLogDefinition>,
  kind: option<Reventless.Plugin.pluginKind>,
}


