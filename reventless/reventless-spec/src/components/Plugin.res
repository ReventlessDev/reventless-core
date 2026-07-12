/** The logical name of a plugin (serializable as JSON). */
@schema
type name = string

/** The semantic version string of a plugin release. */
@schema
type version = string

/**
Classifies the business role of a plugin, carried on `pluginDefinition` so the
plugin-lifecycle read model can segregate infrastructure/commercial/marketplace
plugins from domain plugins in the admin Plugins view. Absent (on definitions
persisted before this field existed) is read as `Domain`.

Canonical here in `reventless-spec` because `pluginDefinition` (a `@schema` type
nested in the lifecycle Message union) needs the sury schema; `ReventlessCore.Plugin_BuiltHook`
re-exports this same type for its deploy-time metadata registry.
*/
@schema
type pluginKind =
  | Domain
  | PlatformInfrastructure
  | Commercial
  | Marketplace

/**
Describes an extension point exported by a plugin.
Included in the plugin's `pluginDefinition` for use by the gateway / host.
*/
@schema
type extensionPointDefinition = {
  name: string,
  commandTopic: string,
  eventTopic: string,
}

/**
Describes an extension imported by a plugin (i.e. a connection to a host plugin's
extension point).
Included in the plugin's `pluginDefinition` for use by the host.
*/
@schema
type extensionDefinition = {
  name: string,
  extensionPointName: string,
  /**
  DCB EventLog source names this extension consumes. Convention: each entry is
  the `name` field of a peer plugin's `dcbEventLogDefinition` (i.e. `${peer}DcbEventLog`).
  The admin uses these to provision cross-plugin SNS subscriptions from peer DCB
  EventTopics → this plugin's EventCollector. `[]` for extensions that only consume
  ExtensionPoint EventTopics.
  */
  dcbSources: array<string>,
}

/**
Describes a DCB EventLog exposed by a plugin.
Included in the plugin's `pluginDefinition` so the admin can provision SNS
subscriptions from this plugin's DCB EventTopic to any peer plugin whose
extension references the DCB log by name.
*/
@schema
type dcbEventLogDefinition = {
  /** Service name carried in event meta — convention: `${plugin.name}DcbEventLog`. */
  name: string,
  /** SNS topic ARN for the DCB EventLog's EventTopic. */
  eventTopicArn: string,
}

/**
Protocol version declaration for a single extension point connection.

Carried in the `ConnectPlugin` handshake so the host can validate schema
compatibility before accepting the extension. Use `[]` when version
negotiation is not needed.
*/
// Protocol version declaration for a single extension point connection.
// Carried in the ConnectPlugin handshake so the host can validate compatibility.
@schema
type extensionProtocol = {
  extensionPointName: string,
  /** SemVer of the command schema the extension was compiled against. */
  commandVersion: string,
  /** SemVer of the event schema the extension was compiled against. */
  eventVersion: string,
}

/**
A GraphQL schema fragment contributed by a plugin.
Encoded as JSON for transport; protocol identifies the schema format (e.g. "graphql").
*/
@schema
type apiSchemaFragment = {encoded: string, protocol: string}

// Sury's nullableAsOption creates T | undefined | null which fails jsonableValidation
// inside union variant payloads. js_nullable creates T | null (no undefined) which is
// JSON-safe and passes jsonableValidation in all contexts.
@module("sury/src/Sury.res.mjs") external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"
let apiSchemaFragmentOptionSchema = _jsNullable(apiSchemaFragmentSchema, ())
let dcbEventLogOptionSchema = _jsNullable(dcbEventLogDefinitionSchema, ())
// js_nullable creates T | null which passes sury's jsonableValidation inside union variant payloads.
let stringOptionSchema = _jsNullable(S.string, ())
let stringArrayOptionSchema = _jsNullable(S.array(S.string), ())
let boolOptionSchema = _jsNullable(S.bool, ())

// ── UI fragment manifest types ────────────────────────────────────────────────

@schema
type panelManifestEntry = {
  fragmentId: string,
  title: string,
  description: string,
  positions: array<string>,
  requiredAccess: @s.matches(stringOptionSchema) option<string>,
}

@schema
type menuEntry = {
  label: string,
  icon: @s.matches(stringOptionSchema) option<string>,
  group: @s.matches(stringOptionSchema) option<string>,
  sortOrder: int,
}

@schema
type pageManifestEntry = {
  fragmentId: string,
  title: string,
  menuEntry: menuEntry,
  requiredAccess: @s.matches(stringOptionSchema) option<string>,
}

@schema
type uiFragmentManifest = {
  remoteEntryUrl: string,
  panels: array<panelManifestEntry>,
  pages: array<pageManifestEntry>,
}

let uiFragmentManifestOptionSchema = _jsNullable(uiFragmentManifestSchema, ())

// ── Plugin structure types (component metadata for Auto UI and event graph) ──

@schema
type commandLevel = Collection | Instance

@schema
type fieldReference = {
  fieldName: string,
  entity: string,
  plugin: @s.matches(stringOptionSchema) option<string>,
}

@schema
type commandDef = {
  name: string,
  schema: string,
  level: commandLevel,
  aggregateIdField: @s.matches(stringOptionSchema) option<string>,
  mutationField: string,
  references: array<fieldReference>,
  /**
  Status values under which this command is meaningful. `None` means the command
  is always available (back-compat default). `Some([…])` lets AutoUI hide the
  command on rows whose status field is not in the set — see `queryableDef.statusField`
  for how the row's status is located. `Some([])` is the defensive "never show" form.
  */
  allowedStates: @s.matches(stringArrayOptionSchema) option<array<string>>,
  /**
  Whether this command variant is exposed in the generated API (a non-`@noApi`
  variant of a non-`@noApi` command). Dev tooling badges API-exposed commands in
  the event graph. js_nullable (T | null) so it stays JSON-safe inside the
  persisted/lifecycle payloads; absent on defs written before this field existed
  (read as None) — those stores must be reset. See [[sury-optional-field-absent-vs-null]].
  */
  apiExposed: @s.matches(boolOptionSchema) option<bool>,
}

@schema
type queryableDef = {
  name: string,
  queryField: string,
  schema: string,
  consumedEventTypes: array<string>,
  linkedWriteSide: array<string>,
  /**
  The field on this entity that carries the human-readable label.
  When the entity's state schema declares one or more `@displayName` annotations,
  this resolves to `"displayName"` (the projected column). Otherwise it falls back
  to the first non-`id` string property, or `"id"` as a last resort.
  */
  labelField: string,
  /**
  Fields appropriate for label-oriented text search.
  Mirrors `labelField` when the entity uses the fallback or single-field label.
  For composite `@displayName` annotations, lists the *raw* underlying source
  fields (so clients with substring indexes can target them directly).
  */
  searchableFields: array<string>,
  /**
  Name of the state field whose value identifies the row's lifecycle status, used
  by AutoUI together with `commandDef.allowedStates` to filter the per-row command
  menu. Resolution order (codegen): (1) field annotated `@status`; (2) a field
  literally named `"status"`; (3) `None`. Spec authors that hand-roll a
  `queryableDef` set this explicitly.
  */
  statusField: @s.matches(stringOptionSchema) option<string>,
  /**
  Component visibility hint (`@@reventless.visibility`). `Some("Internal")` marks a
  ReadModel / StateViewSlice that the deployed AutoUI hides from its menu, drill-down
  pages, web event graph and cross-plugin edges. `None` (absent) means Public. Internal
  components are still CARRIED in `pluginStructure` (tagged here) so developer tools — the
  `reventless-gwt` / VSCode domain graph and dead-code analysis — can see them, per
  Visibility.res. Optional for back-compat: definitions persisted before this field
  existed decode as `None` (Public).
  */
  visibility: @s.matches(stringOptionSchema) option<string>,
  /**
  Intra-plugin grouping band (the "chapter") this component belongs to, captured at
  build time from its source folder by the plugin generator: the first path segment
  under the plugin's `src/` that is not a recognised kind-folder
  (`src/<Chapter>/…/<Component>.res` → `Some("<Chapter>")`; a component directly under a
  kind-folder → `None`). Lets a consumer that renders the event graph from the
  *deployed* plugin structure group components into chapter sub-containers identically
  to the authoring tooling, with no workspace/disk access — the renderer already
  supports the bands (`DomainGraphD2 ~chapters`); only this datum was missing on the
  deployed side. `None` (absent) renders flat. js_nullable (T | null) keeps it JSON-safe
  inside the lifecycle Message union; always written (None → null), so defs persisted
  before this field existed must be reset/re-emitted. See [[deployed-chapter-grouping]].
  */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

/**
One emitted event of a write side, with its field schema. Mirrors `commandDef`
but for the past-tense facts a write side produces: `name` is the event variant
name (e.g. `OrderPlaced`), `schema` is the JSON Schema of that variant's payload
(same `S.toJSONSchema` serialization as `commandDef.schema`, incl. `x-reventless-*`
extensions and the `TAG` const), `references` its cross-entity field links.
Carried so developer tools (the `reventless-dev` / VSCode domain graph) can show
event field rows — AutoUI ignores it. */
@schema
type eventDef = {
  name: string,
  schema: string,
  references: array<fieldReference>,
}

@schema
type writableDef = {
  name: string,
  commands: array<commandDef>,
  producedEventTypes: array<string>,
  consumedEventTypes: array<string>,
  linkedViews: array<string>,
  consistencyRead: @s.matches(stringOptionSchema) option<string>,
  /** Emitted-event field schemas (Phase 6.3). Required like the other write-side
  arrays; `[]` when there are none. The structure is re-derived on every build/
  deploy, so no persisted-data back-compat shim is needed. */
  events: array<eventDef>,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type automationSliceDef = {
  name: string,
  consumedEventTypes: array<string>,
  producedCommandTypes: array<string>,
  targetName: string,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type outboundTranslationSliceDef = {
  name: string,
  consumedEventTypes: array<string>,
  inboundCommandTypes: array<string>,
  targetName: @s.matches(stringOptionSchema) option<string>,
  // Foreign system this slice publishes to — drives the external box (Event Graph).
  externalSystem: @s.matches(stringOptionSchema) option<string>,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type inboundTranslationSliceDef = {
  name: string,
  commandTypes: array<string>,
  targetName: string,
  // Foreign system this slice receives from — drives the external box (Event Graph).
  externalSystem: @s.matches(stringOptionSchema) option<string>,
  /** Chapter grouping band — see `queryableDef.chapter`. */
  chapter: @s.matches(stringOptionSchema) option<string>,
}

@schema
type extensionDef = {
  name: string,
  delegateNames: array<string>,
  eventTypes: array<string>,
  commandTypes: array<string>,
}

/**
Describes an extension point owned by a plugin, from the *producer* side.

`sourceEventTypes` are the owner-plugin internal events (the `Delegate`'s events)
that feed this extension point's published protocol — plugin-qualified to match
`writableDef.producedEventTypes`, so the event graph can link a producing
write-side to the extension point it ultimately feeds. `delegateNames` are the
connected targets (one per `ExtensionPointMapping`).

`commandTypes` are the EP's *inbound* command protocol (the variants of its
`command` type). It is empty (None, read as []) when the EP declares
`command = unit` — a notification-only, events-out boundary that accepts nothing
inward. The event graph uses this to decide whether the EP routes any command (an
empty list means no `routesTo` edge: there is nothing for the EP to route).

Optional (None for a `command = unit` EP). Uses the `js_nullable` pattern (T | null).
A sury field cannot be BOTH absent-tolerant on decode AND JSON-encodable (proven:
S.option = `T|undefined`, nullableAsOption = `T|undefined|null` both decode an absent
key but fail jsonableValidation; js_nullable = `T|null` is the only JSON-safe form but
rejects an absent key). This def is nested in the JSON-encoded lifecycle Message union
(Connect/Heartbeat), so jsonability wins → js_nullable. It always writes the field
(None → null), so it is present-required on decode; a plugin definition persisted
before this field existed must be reset/re-emitted. Read with `->Option.getOr([])`.
*/
@schema
type extensionPointDef = {
  name: string,
  delegateNames: array<string>,
  sourceEventTypes: array<string>,
  commandTypes: @s.matches(stringArrayOptionSchema) option<array<string>>,
}

// js_nullable creates `array | null` (not `| undefined`), which passes sury's
// jsonableValidation inside the pluginStructure union variant payload.
let extensionPointDefArrayOptionSchema = _jsNullable(S.array(extensionPointDefSchema), ())

@schema
type pluginStructure = {
  readModels: array<queryableDef>,
  stateViewSlices: array<queryableDef>,
  stateChangeSlices: array<writableDef>,
  aggregates: array<writableDef>,
  automationSlices: array<automationSliceDef>,
  outboundTranslationSlices: array<outboundTranslationSliceDef>,
  inboundTranslationSlices: array<inboundTranslationSliceDef>,
  extensions: array<extensionDef>,
  // Extension points owned by this plugin (producer side). Optional so plugin
  // definitions persisted before this field existed still decode (absent → None,
  // read as []). js_nullable keeps it JSON-safe inside union variant payloads.
  extensionPoints: @s.matches(extensionPointDefArrayOptionSchema)
  option<array<extensionPointDef>>,
}

let pluginStructureOptionSchema = _jsNullable(pluginStructureSchema, ())

// ── Event graph types (cross-plugin component graph) ──────────────────────────

@schema
type graphNode = {pluginName: string, componentName: string, kind: string}

@schema
type graphEdge = {
  source: graphNode,
  target: graphNode,
  mechanism: string,
  viaEvents: array<string>,
  implicit: bool,
}

@schema
type platformEventGraph = {nodes: array<graphNode>, edges: array<graphEdge>}

/**
The self-description of a deployed plugin, persisted in the plugin's event store.

Used by the gateway to discover extension points, extensions, and protocol versions.
The `eventCollector` field is mutable so it can be set after the heartbeat lambda
registers its own ARN.
*/
@schema
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,
  // Protocol version declarations for each extension point this plugin connects to.
  // Use [] when the plugin does not need version negotiation.
  extensionProtocols: array<extensionProtocol>,
  // GraphQL schema fragment contributed by this plugin (optional, set at build time).
  // Uses @s.matches(apiSchemaFragmentOptionSchema) — js_nullable creates T | null
  // (not T | undefined | null), which passes sury's jsonableValidation inside union variants.
  apiSchemaFragment: @s.matches(apiSchemaFragmentOptionSchema) option<apiSchemaFragment>,
  // API target for schema routing in split-API mode.
  // None/"Domain" → fragment goes to the DomainApi (default).
  // Some("Platform") → fragment goes to the PlatformApi; excluded from DomainApi runtime schema.
  // Uses @s.matches(stringOptionSchema) — js_nullable creates string | null (not string | undefined),
  // which passes sury's jsonableValidation inside union variant payloads.
  apiTarget: @s.matches(stringOptionSchema) option<string>,
  // Component graph metadata — populated by makePluginDefinition; absent for older protocol versions.
  structure: @s.matches(pluginStructureOptionSchema) option<pluginStructure>,
  // DCB EventLog definition for plugins that bundle a DcbEventLog component.
  // Carries the EventTopic ARN so the admin can provision cross-plugin SNS
  // subscriptions from this plugin's DCB topic → peer EventCollectors.
  // None for plugins without a DCB EventLog.
  dcbEventLog: @s.matches(dcbEventLogOptionSchema) option<dcbEventLogDefinition>,
  // Business role of this plugin. Mandatory: `Domain` is the default kind, resolved once
  // at the deploy-metadata → definition boundary (Plugin_Builder). PlatformInfrastructure
  // plugins are segregated out of the admin Plugins list. Payload-less variant → serialises
  // as a bare JSON string, so it is JSON-safe inside the lifecycle Message union without js_nullable.
  kind: pluginKind,
}

