// Behavior module type for aggregate business logic.
// Lives in reventless-spec so application domain code can define behaviors
// without importing the reventless implementation package.

/**
Module type that application code must implement to define aggregate business logic.

A `Behavior.T` module contains the `Spec` (command / event / error types), the
aggregate `state`, and two pure functions plus an initial state value:

- `initialState` — the starting state before any events (represents "not yet created")
- `evolve` — fold an event into the current state
- `decide` — handle a command on the current state, returning `Ok(events)` or `Error(error)`

@example
```rescript
// CategoryBehavior.res
module Spec = Category

@schema
type state = NotCreated | Active({name: string}) | Archived

let initialState = NotCreated

let evolve = (state, event) => switch (state, event) {
  | (NotCreated, CategoryAdded({name})) => Active({name})
  | (Active(_), CategoryRenamed({name})) => Active({name})
  | (Active(_), CategoryArchived(_)) => Archived
  | _ => state
}

let decide = (state, cmd) => switch (state, cmd) {
  | (NotCreated, AddCategory({categoryId, name})) => Ok([CategoryAdded({categoryId, name})])
  | (NotCreated, _) => Error(CategoryNotFound)
  | (Active(_), AddCategory(_)) => Error(CategoryAlreadyExists)
  | (Active(_), RenameCategory({categoryId, name})) => Ok([CategoryRenamed({categoryId, name})])
  | (Active(_), ArchiveCategory({categoryId})) => Ok([CategoryArchived({categoryId})])
  | (Archived, _) => Error(CategoryAlreadyArchived)
}
```
*/
module type T = {
  module Spec: {
    /** The command type. Must carry a `@schema` attribute. */
    @schema
    type command

    /** The event type. Must carry a `@schema` attribute. */
    @schema
    type event

    /** The error type returned when business rules are violated. */
    @schema
    type error
  }

  /** The aggregate's internal state type. Not persisted; rebuilt by replaying events. */
  type state

  /** The starting state before any events have been applied. */
  let initialState: state

  /**
  Fold one event into the current state. Called for every event during replay.
  Must be a pure function — no side effects.
  */
  let evolve: (state, Spec.event) => state

  /**
  Handle a command on the current state.
  Return `Ok(events)` to emit events, or `Error(error)` to reject the command.
  */
  let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>

  /** File URL of this module (`import.meta.url`). Used by AWS builders to derive
      the npm specifier for runtime dynamic imports. */
  let moduleUrl: string
}
