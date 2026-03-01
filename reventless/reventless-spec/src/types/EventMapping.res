/**
The aggregate whose events will be mapped.
Identifies the event topic to subscribe to via `name` and `Id`.
*/
module type Source = {
  let name: string
  module Id: Id.T
  @schema
  type event
}

/**
The aggregate whose commands will be produced.
Identifies the command topic to publish to via `name` and `Id`.
*/
module type Target = {
  let name: string
  module Id: Id.T
  @schema
  type command
}

/**
The outcome of an event-to-command mapping.

A `map` function returns an array of `action` values describing what should
happen when a source event is observed.

- `Publish(id, cmd)` — immediately publish a command to the target aggregate
- `PublishDelayed(id, cmd, seconds)` — publish a command after a delay
- `PublishAsync(promise)` — resolve a promise and publish all resulting commands
- `AddToCounterTarget(target)` — register a counter threshold target
- `Count(id)` — increment a counter by 1
- `CountMulti(id, n)` — increment a counter by `n`

@example
```rescript
// Route CategoryArchived to update the Products read model
let map = (sourceId, event, _queryEngine) => switch event {
  | CategoryArchived({categoryId}) =>
    [EventMapping.Publish(categoryId, ArchiveProductsInCategory({categoryId}))]
  | _ => []
}
```
*/
type action<'id, 'command> =
  /** Immediately publish a command to the target aggregate. */
  | Publish('id, 'command)
  /** Publish a command after `int` seconds. */
  | PublishDelayed('id, 'command, int)
  /** Resolve a promise and publish all resulting `(id, command)` pairs. */
  | PublishAsync(promise<array<('id, 'command)>>)
  /** Register a counter threshold target (used with the Counter component). */
  | AddToCounterTarget(Counter.counterTarget)
  /** Increment a named counter by 1. */
  | Count(Counter.counterId)
  /** Increment a named counter by `n`. */
  | CountMulti(Counter.counterId, int)

/**
Module type for an event-to-command mapping.

Implement this to route events from one aggregate to commands on another.
The `map` function is pure — use `PublishAsync` for async lookups.

@example
```rescript
module CategoryToProduct: EventMapping.T = {
  module Source = Category
  module Target = Product
  let map = (sourceId, event, _q) => switch event {
    | CategoryArchived({categoryId}) =>
      [Publish(categoryId, ArchiveProductsInCategory({categoryId}))]
    | _ => []
  }
}
```
*/
module type T = {
  module Source: Source
  module Target: Target
  /**
  Map a source event to zero or more target actions.

  - `Source.Id.t` — the ID of the aggregate that emitted the event
  - `Source.event` — the domain event payload
  - `QueryEngine.operations` — read-only query engine for async lookups
  */
  let map: (
    Source.Id.t,
    Source.event,
    QueryEngine.operations,
  ) => array<action<Target.Id.t, Target.command>>
}
