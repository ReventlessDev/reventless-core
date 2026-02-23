module type Spec = {
  module Id = Id.String

  let name: string

  @schema
  type command
  @schema
  type event
  @schema
  type directive
}

type outputs = {
  name: string,
  aggregateNames: array<string>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventTopic: Pulumi.Output.t<EventTopic.outputs>,
}

// eventHandler type is defined in reventless (references Plugin.pluginDefinition which
// would create a circular dependency: ExtensionPoint → Plugin → ExtensionPoint).
// The spec-level T uses abstract `type operations` to avoid the cycle.

module type T = {
  type operations
  type component
  let make: (
    ~aggregateResources: dict<array<Adapter.resource>>,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~scheduler: Scheduler.operations,
    ~queryEngine: QueryEngine.operations,
    ~resourceNaming: ResourceNaming.operations,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
}

// Mappings uses ExtensionPointMapping.T (the pre-compiled mapping type produced by
// ExtensionPointMapping.Make). App developers call Make themselves before assembling Mappings.
module type Mappings = {
  module Spec: ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}
