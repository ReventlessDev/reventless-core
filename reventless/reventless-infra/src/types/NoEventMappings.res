/**
Produces an empty `EventMapper.Mappings` module for aggregates that do not
need to route their events to other aggregates.

Use this when creating an aggregate via `Platform.Aggregate.Make` and the
aggregate's events do not trigger commands on other aggregates.

@example
```rescript
// CatalogPlugin.res
module CategoryAggregate = Platform.Aggregate.Make(
  Category,
  CategoryBehavior,
  NoEventMappings.Make(Category),
)
```
*/
module Make = (Target: Reventless.EventMapping.Target): (
  EventMapper.Mappings with module Target := Target
) => {
  module type Mapping = Reventless.EventMapping.T with module Target := Target
  let moduleUrl: string = %raw(`import.meta.url`)
  let mappings = []
  let counter = None
}
