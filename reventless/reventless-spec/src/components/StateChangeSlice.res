/**
Module type for a DCB write-side state change slice specification.

A `StateChangeSlice` is the DCB equivalent of an aggregate: it processes
commands by reading the relevant events from a shared `DcbEventLog`, building
a `state` (ephemeral read model), and appending new events conditioned
on no concurrent changes to the same entities.

Each slice declares its own `event` (what it emits) and `consumedEvent`
(what it reads to build its decision model). Consumed events may be payload-less,
carry a field subset, or use the full shape.

@example
```rescript
// AddCategory.res
let name = "AddCategory"

type state = {exists: bool, archived: bool}
let initialState = {exists: false, archived: false}

@schema type consumedEvent =
  | CategoryAdded
  | CategoryArchived

let evolve = (state, event) => switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
}

@schema type command = AddCategory({categoryId: @s.matches(DcbTag.string) string, name: string})
@schema type error = CategoryAlreadyExists

@schema type event =
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})

let decide = (state, command) => switch command {
  | AddCategory({categoryId, name}) =>
    if state.exists { Error(CategoryAlreadyExists) }
    else { Ok([CategoryAdded({categoryId, name})]) }
}
```
*/
module type Spec = {
  /** Logical name of this slice (used as a command topic prefix). */
  let name: string
  let moduleUrl: string

  /**
  The ephemeral state built by replaying relevant events.
  Not persisted — reconstructed for each command by reading from the DCB log.
  */
  type state

  /** The initial (empty) state before any events have been applied. */
  let initialState: state

  /**
  Events this slice reads to build its decision model (in evolve).
  Only needs the fields required for the decision — no tag annotations needed.
  May be payload-less for events where only existence matters.
  Must carry `@schema`.
  */
  @schema
  type consumedEvent

  /**
  Folds one consumed event into the state during the read phase.
  Must be a pure function — no side effects.
  Receives only events declared in `consumedEvent` — no wildcard needed.
  */
  let evolve: (state, consumedEvent) => state

  /** Commands this slice handles. Must carry `@schema`. */
  @schema
  type command

  /** Business rule violation errors. Must carry `@schema`. */
  @schema
  type error

  /** Identity type — always `Id.String` for DCB slices. */
  module Id: Id.T

  /** Events this slice emits (from decide). Must carry `@schema` and include tag annotations. */
  @schema
  type event

  /**
  Decides what events to append given the current state and the command.
  Return `Ok(events)` to append, or `Error(error)` to reject the command.
  */
  let decide: (state, command) => result<array<event>, error>

  /** Schema for the command type — used to extract DCB tags for the conditional read. */
  let commandSchema: S.t<command>
}
