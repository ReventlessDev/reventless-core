// Runtime-safe plugin hook registry — no Pulumi imports.
//
// Contains only plain-data types and mutable callback refs that are safe
// to import from Lambda handlers. Plugin_Helpers re-exports everything
// here for backward compatibility.
//
// Separated from Plugin_Helpers because Plugin_Helpers imports Pulumi
// for deploy-time Output serialization, which makes it unusable at runtime.

// ---------------------------------------------------------------------------
// Plugin classification types — optional metadata consumers can attach to
// describe a plugin's role and origin.
// ---------------------------------------------------------------------------

/** Classifies the business role of a plugin. Absent defaults to Domain. */
type pluginKind =
  | Domain
  | PlatformInfrastructure
  | Commercial
  | Marketplace

/** Classifies the architectural style of a plugin's domain model. */
type architectureType =
  | Aggregate
  | Dcb
  | Hybrid
  | SdkService
  | Mcp
  | Mixed

// ---------------------------------------------------------------------------
// Field-level schema types — used by SchemaWalker to expose the structural
// shape of command, event, and state types at deploy time.
// ---------------------------------------------------------------------------

/** A single field extracted from a sury object schema. */
type fieldSchema = {
  name: string,
  /** Human-readable type: "string", "float", "bool", "int", "array", "object", "option", "union", "unknown" */
  typeDescription: string,
  /** true = required field (field: T); false = optional (field?: T) */
  isRequired: bool,
}

/** One constructor in a variant type. */
type constructorSchema = {
  name: string,
  fields: array<fieldSchema>,
}

/** Schema for one named type (a command, event, or state type). */
type typeSchema = {
  typeName: string,
  /** "record" | "variant" | "unknown" */
  kind: string,
  fields: array<fieldSchema>,
  constructors?: array<constructorSchema>,
  /** SHA256 of sorted "name:typeDescription:isRequired" tuples — stable shape fingerprint. */
  structuralHash: string,
}

// ---------------------------------------------------------------------------
// Shared schema type — used by both pluginBuiltComponent and
// pluginDeployedComponent to describe per-component schema details.
// ---------------------------------------------------------------------------
type pluginDeployedSchema = {
  commandTypes?: array<string>,
  eventTypes?: array<string>,
  errorTypes?: array<string>,
  stateType?: string,
  sourceNames?: array<string>,
  queryFields?: array<string>,
  consumedEventTypes?: array<string>,
  producedCommandTypes?: array<string>,
  sharedBy?: array<string>,
  extensionPointName?: string,
  providerPlugin?: string,
  subscriberPlugins?: array<string>,
  /** Field-level schema per command type (one entry per variant constructor). */
  commandSchemas?: array<typeSchema>,
  /** Field-level schema per event type (one entry per variant constructor). */
  eventSchemas?: array<typeSchema>,
  /** Field-level schema for the state type. */
  stateSchema?: typeSchema,
}

// ---------------------------------------------------------------------------
// Plugin-built hook — fires synchronously after plugin construction with a
// plain-data summary of the plugin's components.
// ---------------------------------------------------------------------------
type pluginBuiltComponent = {
  name: string,
  kind: string,
  schema: pluginDeployedSchema,
}

type pluginBuiltInfo = {
  name: string,
  version: string,
  kind?: pluginKind,
  displayName?: string,
  vendor?: string,
  architectureType?: architectureType,
  components: array<pluginBuiltComponent>,
}

// Registry for component schemas — populated during Plugin_Builder.construct,
// read by exportPluginOutputs to populate pluginDeployedComponent.schema.
let componentSchemaRegistry: dict<pluginDeployedSchema> = Dict.make()

// Optional metadata consumers register before platform construction to
// attach classification info to pluginBuiltInfo / pluginDeployedInfo.
type pluginMetadata = {
  kind?: pluginKind,
  displayName?: string,
  vendor?: string,
  architectureType?: architectureType,
}

let pluginMetadataRegistry: ref<option<pluginMetadata>> = ref(None)

let registerPluginMetadata = (metadata: pluginMetadata) => {
  pluginMetadataRegistry.contents = Some(metadata)
}

let clearPluginMetadata = () => {
  pluginMetadataRegistry.contents = None
}

let onPluginBuiltHook: ref<option<pluginBuiltInfo => unit>> = ref(None)

let registerOnPluginBuilt = (hook: pluginBuiltInfo => unit) => {
  onPluginBuiltHook.contents = Some(hook)
}

let clearOnPluginBuilt = () => {
  onPluginBuiltHook.contents = None
}
