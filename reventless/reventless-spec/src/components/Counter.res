/**
A named counter (e.g. `"ProductCount"`). Used as a key in the counts database.
Multiple counters can exist within the same `Counter` component.
*/
type counterId = string

/**
An opaque reference string that de-duplicates counter increments.

Each unique `reference` is counted at most once per `counterId`.
Typically set to the event's message ID to make increments idempotent.
*/
type reference = string

/**
A counter threshold target.

When the count for `counterId` reaches `target`, the event mapping
framework fires the associated command.
*/
type counterTarget = {
  counterId: counterId,
  target: int,
}

/**
A single counter increment item.

- `counterId` — which counter to increment
- `reference` — idempotency key (e.g. the triggering event's message ID)
- `inc` — how much to increment by (usually 1)
*/
type countItem = {
  counterId: counterId,
  reference: reference,
  inc: int,
}

/**
A counter threshold target with an idempotency reference.

Used by `addToCounterTarget` to register that a target has been claimed by
a specific `reference`, preventing duplicate threshold triggers.
*/
type counterTargetRef = {
  counterId: counterId,
  target: int,
  targetRef: reference,
}

/**
Deploy-time outputs produced when a `Counter` component is provisioned.

- `referencesDb` — tracks which references have already been counted (dedup)
- `countsDb` — stores the current count per `counterId`
*/
type outputs = {referencesDb: QueryDb.outputs, countsDb: QueryDb.outputs}

/** Increments one or more counters. Each item is applied idempotently via its `reference`. */
type count = array<countItem> => promise<unit>

/**
Registers a threshold target, claiming it with a `targetRef`.
When the count reaches `target`, the event mapping's `AddToCounterTarget` action fires.
*/
type addToCounterTarget = counterTargetRef => promise<unit>

/**
Runtime operations exposed by a `Counter` component.
Available inside event mapping `map` functions via the injected `operations` record.
*/
type operations = {count: count, addToCounterTarget: addToCounterTarget}

/**
Processes a stream of raw event JSON values to extract and apply counter increments.
Used internally by the counter's Lambda handler.
*/
type jsonEventsHandler = Stream.t<JSON.t, string, unit> => Effect.t<unit, string, unit>

/**
Module type for a `Counter` component.

The `Counter` component maintains named reference-counted thresholds.
When a count crosses a configured threshold, the associated event mapping
fires a command to the target aggregate.
*/
module type T = {
  type component
  let make: (
    ~name: string,
    ~jsonEventsHandler: jsonEventsHandler,
    ~ttl: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
