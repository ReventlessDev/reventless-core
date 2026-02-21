type outputs = {
  name: string,
  extensionPointName: string,
  aggregateNames: array<string>,
}

// eventHandler type is defined in reventless (references Plugin.pluginDefinition which
// would create a circular dependency: Extension → Plugin → Extension).
// The spec-level T uses abstract `type operations` to avoid the cycle.

module type T = {
  type operations
  type component
  let make: (
    ~publishToCorePluginExtensionPoint: CommandTopic.publishJsons,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~readModelNamesForSourceName: dict<array<string>>,
    ~publishToReadModels: dict<EventCollector.enqueueEvent>,
    ~queryEngine: QueryEngine.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
}
