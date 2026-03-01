// Behavior module type for aggregate business logic.
// Lives in reventless-spec so application domain code can define behaviors
// without importing the reventless implementation package.
//
// A module satisfying this type is structurally compatible with Reventless.Behavior.T
// because all referenced types (Message.context, Handler.errorHandler) are identical
// in both packages.

/**
Configuration for resolving GraphQL field arguments from the command schema.

`commandSchema` is the sury schema for the command type.
`fields` lists the field names that the GraphQL resolver should accept as arguments.
*/
type resolverConfig<'command> = {
  commandSchema: S.t<'command>,
  fields: array<string>,
}

/**
Module type that application code must implement to define aggregate business logic.

A `Behavior.T` module contains the `Spec` (command / event / error types), the
aggregate `state`, and four pure functions:

- `init` — produce the initial state from the first event
- `apply` — fold an event into the current state
- `create` — handle a command when no state exists yet (aggregate creation)
- `execute` — handle a command on an existing state

@example
```rescript
// CategoryBehavior.res
module Spec = Category

@schema
type state = Active({name: string}) | Archived

let resolverConfig = {Behavior.commandSchema, fields: []}

let init = event => switch event {
  | CategoryAdded({name}) => Active({name})
  | _ => throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
}

let apply = (state, event) => switch (state, event) {
  | (Active(_), CategoryRenamed({name})) => Active({name})
  | (Active(_), CategoryArchived(_)) => Archived
  | _ => state
}

let create = (cmd, _ctx, onError) => switch cmd {
  | AddCategory({categoryId, name}) => [CategoryAdded({categoryId, name})]
  | _ => onError(CategoryNotFound, cmd, _ctx)
}

let execute = (state, cmd, ctx, onError) => switch (state, cmd) {
  | (Active(_), AddCategory(_)) => onError(CategoryAlreadyExists, cmd, ctx)
  | (Active(_), RenameCategory({categoryId, name})) => [CategoryRenamed({categoryId, name})]
  | (Active(_), ArchiveCategory({categoryId})) => [CategoryArchived({categoryId})]
  | (Archived, _) => onError(CategoryAlreadyArchived, cmd, ctx)
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

  /** GraphQL resolver configuration used by the API layer. */
  let resolverConfig: resolverConfig<Spec.command>

  /**
  Produce the initial state from the very first event (aggregate creation event).
  Called once when an aggregate receives its first event.
  */
  let init: Spec.event => state

  /**
  Fold one event into the current state. Called for every subsequent event during replay.
  Must be a pure function — no side effects.
  */
  let apply: (state, Spec.event) => state

  /**
  Handle a command when the aggregate does not yet exist (state = None).
  Return the events to emit. Call `onError` to recover from business rule violations.
  */
  let create: (
    Spec.command,
    Message.context,
    Handler.errorHandler<Spec.error, Spec.command, Spec.event>,
  ) => array<Spec.event>

  /**
  Handle a command on an existing aggregate state.
  Return the events to emit. Call `onError` to recover from business rule violations.
  */
  let execute: (
    state,
    Spec.command,
    Message.context,
    Handler.errorHandler<Spec.error, Spec.command, Spec.event>,
  ) => array<Spec.event>
}
