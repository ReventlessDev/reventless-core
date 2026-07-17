/**
Deploy-time outputs produced when an `Extension` is provisioned.

- `name` — the extension's logical name
- `extensionPointName` — the extension point this extension connects to
- `aggregateNames` — names of aggregates wired through this extension
*/
type outputs = {
  name: string,
  extensionPointName: string,
  aggregateNames: array<string>,
}

// eventHandler type is defined in reventless (references Plugin.pluginDefinition which
// would create a circular dependency: Extension → Plugin → Extension).
// The spec-level T uses abstract `type operations` to avoid the cycle.

/**
Module type for a provisioned extension component.

An `Extension` connects a host plugin's extension point to one or more aggregates,
translating commands and events in both directions via `ExtensionMapping.Mapping`.

`operations` is left abstract at the spec level to avoid a circular dependency.
The concrete type is defined in the `reventless` package.
*/
module type T = {
  type operations
  type component
  let make: (
    ~publishToPluginExtensionPoint: CommandTopic.publishJsons,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: dict<array<string>>,
    ~publishToReadModels: dict<EventCollector.enqueueEvent>,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
}

/**
Pre-build blueprint for an extension — compiled mappings that have not yet been
instantiated as a Pulumi component.

`Plugin.make` receives blueprints, groups them by extension point name,
auto-merges mappings for the same EP, sets the component name to the plugin
name, and builds the actual `Extension` component.
*/
module type Blueprint = {
  module Spec: ExtensionMapping.Spec
  module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
  let name: string
  // npm-style specifier of the user extension file (the one declaring the
  // `module Mapping`). Threaded from the user-facing Mapping.moduleUrl by
  // Platform.Extension.Make so deploy-side helpers can emit HANDLER_CONFIG
  // entries that let the runtime dynamic-import the user mapping at cold
  // start.
  let moduleUrl: string
  // npm-style specifier of the Delegate (aggregate / slice) the extension
  // delegates to. Threaded from Mapping.delegateModuleUrl by Platform.Extension.Make.
  let delegateModuleUrl: string
  let mappings: array<module(Mapping)>
}
