/**
The event source that a `SideEffect.T` module listens to.

Mirrors the aggregate `EventLog.T` shape — the adapter uses `name` and `Id`
to subscribe to the correct event topic.
*/
module type Source = {
  let name: string
  module Id: Id.T
  /** The event type whose emissions trigger this side effect. */
  @schema
  type event
}

/**
Module type for an imperative side effect triggered by aggregate events.

Side effects are registered on a `Task` and executed after the event is stored.
They have read access to the query engine but do NOT emit new events or commands.

@example
```rescript
module NotifyOnCategoryAdded: SideEffect.T = {
  module Source = Category
  let execute = async (id, _meta, event, _queryEngine) => switch event {
    | CategoryAdded({name}) =>
      Console.log2("Category added:", name)
    | _ => ()
  }
}
```
*/
module type T = {
  module Source: Source
  /**
  Called once for each event emitted by `Source`.

  - `id` — the aggregate ID that emitted the event
  - `meta` — the message envelope metadata
  - `event` — the domain event payload
  - `queryEngine` — read-only access to all plugin read models
  */
  let execute: (Source.Id.t, Message.meta, Source.event, QueryEngine.operations) => promise<unit>
}
