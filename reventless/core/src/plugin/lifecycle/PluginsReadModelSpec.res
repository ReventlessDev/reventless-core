@@reventless.spec("Plugins")

// Who may read this view. Declared rather than left to default, because the
// default was `AllowAuthenticated` and it was not true: `PluginBaseFragment`
// hand-wrote an `Admin` Cognito gate beside it, and the local platform serves
// every `Platform_*` field behind an `Admin` wrapper. Three statements of one
// rule, one of which disagreed with the other two.
//
// Stating it here makes the spec the source. The AppSync directive comes from
// this (spec-level `permission` outranks the legacy `{tableName, group}` pair),
// and so does the `requiredAccess` the platform publishes — so a shell can gate
// the Plugins view up front instead of offering it and meeting a refusal.
@@reventless.authorize(AllowGroups(["Admin"]))

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
  // Projection/storage only — never on the GraphQL surface. `@internal` says so
  // on the field, where the next person to edit the record will see it; the same
  // three names used to live in a hand-written exclude list in `PluginBaseFragment`
  // that nothing kept in step with this declaration.
  @internal eventCollector: string,
  extensionPoints: array<Reventless.Plugin.extensionPointDefinition>,
  @internal extensionPointNames: array<string>,
  @internal extensionNames: array<string>,
  extensions: array<Reventless.Plugin.extensionDefinition>,
  // Annotated rather than renamed to `lifecycle` to meet the convention: `status`
  // is published in the SDL, in stored rows and in the UI's hand-written plugin
  // views. Without this the transition check has no states to compare and passes
  // while verifying nothing.
  @lifecycle status: status,
  statusChange: Message.statusChange,
  // Stored as the **untagged** offload wire JSON (a bare fragment, or an
  // `{$offload: {...}}` reference) — NOT the `Offload.payload` variant. The QueryDb
  // write path marshals the raw ReScript value straight to DynamoDB without
  // sury-encoding through this field's schema, so a variant would persist as its
  // runtime `{TAG, _0}` shape and no reader could parse it.
  // PluginsProjection.displayState writes it via Offload.toJson.
  //
  // `@hidden`, not `@internal`: the field IS on the API and the host shell fetches
  // it through a dedicated resolver path. What it must not be is a column in a
  // generated list view — it is a multi-kilobyte JSON blob, and a query that names
  // it drags one per row over the wire to render a cell nobody reads.
  @hidden apiSchemaFragment: option<JSON.t>,
  // API target for split-API schema routing. Absent/None means "Domain" (backward compat).
  // "Platform" → excluded from DomainApi runtime schema stitching in updateApiSchema.
  apiTarget?: string,
  // Plugin structure (component metadata) — surfaced via Platform_ComponentDefinitions.
  // None for older plugins whose protocol version did not carry the field. Same
  // untagged-JSON storage as apiSchemaFragment above; the ComponentDefinitions
  // Lambda detects the `$offload` sentinel and resolves it from S3.
  //
  // `@hidden` for the same reason, and more so: this is the larger of the two
  // blobs.
  @hidden structure: option<JSON.t>,
  // DCB EventLog definition for plugins that bundle a DcbEventLog component.
  // Admin's manageSubscriptions uses this to wire cross-plugin SNS subscriptions
  // from this plugin's DCB topic → peer EventCollectors (and vice-versa). None
  // for pure-aggregate plugins or for plugins persisted before Phase 4.
  dcbEventLog: option<Reventless.Plugin.dcbEventLogDefinition>,
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


