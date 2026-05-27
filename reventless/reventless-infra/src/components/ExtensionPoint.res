/**
Deploy-time outputs produced when an `ExtensionPoint` is provisioned.

- `name` — the extension point's logical name
- `aggregateNames` — names of aggregates connected via `ExtensionPointMapping`
- `commandTopic` — the inbound command queue for extensions to publish to
- `eventTopic` — the outbound event topic extensions subscribe to
*/
type outputs = {
  name: string,
  aggregateNames: array<string>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventTopic: Pulumi.Output.t<EventTopic.outputs>,
  // Module URLs preserved from the Spec and Mappings packed into Make. The
  // EventCollector runtime needs them at HANDLER_CONFIG-build time to wire
  // outgoing event publication for this extension point — see
  // `Plugin_Helpers.registerEventCollectorContext` and the `extensionPointEntry`
  // type that's serialised into the Lambda's HANDLER_CONFIG.
  specModule: string,
  mappingsModule: string,
}

// eventHandler type is defined in reventless (references Plugin.pluginDefinition which
// would create a circular dependency: ExtensionPoint → Plugin → ExtensionPoint).
// The infra-level T uses abstract `type operations` to avoid the cycle.

/**
A collection of `ExtensionPointMapping.T` modules connecting aggregates to
this extension point.

Pass a `Mappings` module to `Platform.ExtensionPoint.Make` to register all
aggregate-to-extension-point connections.
*/
module type Mappings = {
  module Spec: ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let name: string
  let moduleUrl: string
  let mappings: array<module(Mapping)>
}

/**
Module type for a provisioned extension point component.

`operations` is left abstract to avoid a circular dependency between
`ExtensionPoint`, `Plugin`, and back. The concrete type is defined in
the `reventless` package.
*/
module type T = {
  type operations
  type component
  let make: (
    ~aggregateResources: dict<array<Adapter.resource>>,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~scheduler: Scheduler.operations,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~resourceNaming: ResourceNaming.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
}
