/** The logical name of a plugin (serializable as JSON). */
@schema
type name = string

/** The semantic version string of a plugin release. */
@schema
type version = string

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
// js_nullable creates T | null which passes sury's jsonableValidation inside union variant payloads.
let stringOptionSchema = _jsNullable(S.string, ())

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
type commandDef = {
  name: string,
  schema: string,
  level: commandLevel,
  aggregateIdField: @s.matches(stringOptionSchema) option<string>,
  mutationField: string,
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
}

@schema
type writableDef = {
  name: string,
  commands: array<commandDef>,
  producedEventTypes: array<string>,
  consumedEventTypes: array<string>,
  linkedViews: array<string>,
  consistencyRead: @s.matches(stringOptionSchema) option<string>,
}

@schema
type automationSliceDef = {
  name: string,
  consumedEventTypes: array<string>,
  producedCommandTypes: array<string>,
  targetName: string,
}

@schema
type outboundTranslationSliceDef = {
  name: string,
  consumedEventTypes: array<string>,
  inboundCommandTypes: array<string>,
  targetName: @s.matches(stringOptionSchema) option<string>,
}

@schema
type inboundTranslationSliceDef = {
  name: string,
  commandTypes: array<string>,
  targetName: string,
}

@schema
type extensionDef = {
  name: string,
  delegateNames: array<string>,
  eventTypes: array<string>,
  commandTypes: array<string>,
}

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
  // UI fragment manifest contributed by this plugin (optional, absent for pure backend plugins).
  uiFragments: @s.matches(uiFragmentManifestOptionSchema) option<uiFragmentManifest>,
  // Component graph metadata — populated by makePluginDefinition; absent for older protocol versions.
  structure: @s.matches(pluginStructureOptionSchema) option<pluginStructure>,
}

