/**
Module type for an extension point's identity and schema specification.

An extension point is a bidirectional protocol boundary: it exposes a
command topic for extensions to publish to, and an event topic that
extensions subscribe to. The `directive` type is used for internal
routing signals that are not exposed as public events.

Note: `module Id = Id.String` is fixed — extension points always use string IDs.
*/
module type Spec = {
  module Id = Id.String

  /** Logical extension point name (used as a topic name prefix). */
  let name: string

  /** Commands that extensions can send to this extension point. Must carry `@schema`. */
  @schema
  type command
  /** Events that this extension point emits to subscribed extensions. Must carry `@schema`. */
  @schema
  type event
  /** Internal routing directives (not exposed externally). Must carry `@schema`. */
  @schema
  type directive
}

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
}

// eventHandler type is defined in reventless (references Plugin.pluginDefinition which
// would create a circular dependency: ExtensionPoint → Plugin → ExtensionPoint).
// The spec-level T uses abstract `type operations` to avoid the cycle.

/**
Module type for a provisioned extension point component.

`operations` is left abstract at the spec level to avoid a circular dependency
between `ExtensionPoint`, `Plugin`, and back. The concrete type is defined in
the `reventless` package.
*/
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

/**
A collection of `ExtensionPointMapping.T` modules connecting aggregates to
this extension point.

Pass a `Mappings` module to `Platform.ExtensionPoint.Make` to register all
aggregate-to-extension-point connections.
*/
// Mappings uses ExtensionPointMapping.T (the pre-compiled mapping type produced by
// ExtensionPointMapping.Make). App developers call Make themselves before assembling Mappings.
module type Mappings = {
  module Spec: ExtensionPointMapping.Spec
  module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
  let mappings: array<module(Mapping)>
}
