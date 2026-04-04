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
