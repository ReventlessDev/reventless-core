/**
Deploy-time outputs produced when an `EventMapper` is provisioned.

An `EventMapper` subscribes to an aggregate's event topic and routes events
to one or more target aggregate command topics, optionally via a `Counter`.
*/
type outputs = {
  name: string,
  eventCollector: Pulumi.Output.t<EventCollector.outputs>,
  counter?: Counter.outputs,
}

/**
A collection of `EventMapping.T` modules that route events from one aggregate
to commands on one or more target aggregates.

Pass a `Mappings` module to `Platform.Aggregate.Make` as the third argument.
Use `NoEventMappings.Make(TargetSpec)` when no routing is needed.

@example
```rescript
// CatalogPlugin.res
module CategoryMappings: Mappings with module Target := CategoriesReadModel = {
  module CategoryMappings = Mappings.Make(CategoriesReadModel)
  module type Mapping = CategoryMappings.Mapping
  let mappings = CategoriesProjections.mappings
}
```
*/
module type Mappings = {
  module Target: Reventless.EventMapping.Target
  module type Mapping = Reventless.EventMapping.T with module Target := Target
  let mappings: array<module(Mapping)>
  /** Optional counter component for threshold-based command triggers. */
  let counter: option<module(Counter.T)>
}
