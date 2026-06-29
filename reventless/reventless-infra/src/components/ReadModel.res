/**
Deploy-time outputs produced when a `ReadModel` is provisioned.

- `name` — the read model's logical name
- `queryDb` — the underlying query database outputs (DynamoDB table)
- `eventCollector` — the inbound event queue
- `sourceNames` — names of all aggregates whose events feed this read model
*/
type outputs = {
  name: string,
  queryDb: QueryDb.outputs,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  sourceNames: array<string>,
}

/**
Runtime operations exposed by a `ReadModel` component.
Used by the aggregate runtime to push events into the read model's event queue.
*/
type operations = {enqueueEvent: EventCollector.enqueueEvent}

/**
Module type produced by `Platform.ReadModel.Make(Spec, Mappings)`.

@example
```rescript
// CatalogPlugin.res
module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryMappings)

let rm = CategoryReadModel.make(~api, ~apiRole, ~allEventTopics, ~opts=?)
```
*/
module type T = {
  module Spec: Reventless.ReadModel.Spec
  type api
  type role
  type component
  /** Names of aggregates whose events feed this read model (from Projection.Mapping.sourceName). */
  let sourceNames: array<string>
  /** Bare event-variant names this read model consumes, unioned across every projection
      mapping's source event schema (Projection.Mapping.sourceEventSchema). Unlike
      `sourceNames` (the source aggregate / DCB-log names) this names the actual events — so
      a DCB-log-sourced mapping (e.g. consuming `OrderPlaced`) is captured, which sourceNames
      cannot express. Plugin_Structure qualifies + exposes these as `queryableDef.consumedEventTypes`. */
  let consumedEventNames: array<string>
  let make: (
    ~api: api,
    ~apiRole: role,
    ~allEventTopics: EventTopic.allOutputs,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  /** Signal that all sources have been registered; finalises the read model. */
  let finish: unit => unit
}
