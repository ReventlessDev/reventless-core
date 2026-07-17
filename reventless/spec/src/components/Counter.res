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
