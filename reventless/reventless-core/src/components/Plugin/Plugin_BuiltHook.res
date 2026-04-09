// Runtime-safe plugin hook registry — no Pulumi imports.
//
// Contains only plain-data types and mutable callback refs that are safe
// to import from Lambda handlers. Plugin_Helpers re-exports everything
// here for backward compatibility.
//
// Separated from Plugin_Helpers because Plugin_Helpers imports Pulumi
// for deploy-time Output serialization, which makes it unusable at runtime.

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
  components: array<pluginBuiltComponent>,
}

// Registry for component schemas — populated during Plugin_Builder.construct,
// read by exportPluginOutputs to populate pluginDeployedComponent.schema.
let componentSchemaRegistry: ref<dict<pluginDeployedSchema>> = ref(Dict.make())

let onPluginBuiltHook: ref<option<pluginBuiltInfo => unit>> = ref(None)

let registerOnPluginBuilt = (hook: pluginBuiltInfo => unit) => {
  onPluginBuiltHook.contents = Some(hook)
}

let clearOnPluginBuilt = () => {
  onPluginBuiltHook.contents = None
}
