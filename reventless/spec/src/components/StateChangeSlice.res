/**
Module types for a DCB write-side state change slice.

A `StateChangeSlice` is the DCB equivalent of an aggregate: it processes
commands by reading the relevant events from a shared `DcbEventLog`, building
a `state` (ephemeral read model), and appending new events conditioned
on no concurrent changes to the same entities.

Plan 02 splits the merged spec into two module types:

- `Spec` — types, identity, schemas. The structural contract.
- `Behavior` — `state`, `initialState`, `evolve`, `decide`. The state machine.

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

/**
The lean Spec for a StateChangeSlice — types, identity, schemas. State and
state-evolution functions live in the sibling `Behavior` module type.
*/
module type Spec = {
  /** Logical name of this slice (used as a command topic prefix). */
  let name: string
  let moduleUrl: string

  /** Identity type — always `Id.String` for DCB slices. */
  module Id: Id.T

  /**
  Events this slice reads to build its decision model (in `evolve`).
  Only needs the fields required for the decision — no tag annotations needed.
  May be payload-less for events where only existence matters.
  Must carry `@schema`.
  */
  @schema
  type consumedEvent

  /** Commands this slice handles. Must carry `@schema`. */
  @schema
  type command

  /** Business rule violation errors. Must carry `@schema`. */
  @schema
  type error

  /** Events this slice emits (from `decide`). Must carry `@schema` and include tag annotations. */
  @schema
  type event

  /** Schema for the command type — used to extract DCB tags for the conditional read. */
  let commandSchema: S.t<command>

  /** Authorization rule evaluated at the GraphQL resolver entry before any
      command is dispatched. Auto-injected by `@@reventless.spec` and on
      structurally-detected inline spec modules — defaults to
      `AllowAuthenticated`; override at the file/module level with
      `@@reventless.authorize(<rule>)`. */
  let commandAuthorization: command => Authorization.permission

  /** The lifecycle enum this component's commands move a row through — the
      linked view's own, e.g. `type lifecycleState = Customers.accountStatus`.
      Auto-injected as `unit` alongside the default below; a host that declares
      `commandTransition` declares this too, and the pair is what makes every
      edge name one lifecycle. */
  type lifecycleState

  /** The lifecycle edge each command owns, read while the plugin structure is
      assembled. Auto-injected as `_ => Unrestricted` by `@@reventless.spec`,
      which leaves `@transition` in charge; a host that writes the switch by
      hand takes charge instead, and gets an exhaustive one over typed states.
      See `Transition`. */
  let commandTransition: command => Transition.t<lifecycleState>

  /** The domain traits grafted into this component, as values the trait packages
      export — `[TraitAttachments.Attachments.declaration]`. Auto-injected as `[]`
      by `@@reventless.spec`, so a component that is nobody's graft says so without
      a line. A graft names its trait here and the structure records it, which is
      the only way a deployed plugin can answer "where did this come from". See
      `Trait`. */
  let traits: array<Trait.t>

  /** Decision-read consistency mode for this slice's optimistic-concurrency
      retry loop. Auto-injected by `@@reventless.spec` and on
      structurally-detected inline spec modules — defaults to
      `EscalateOnRetry` (eventual first, strong on retry); override at the
      file/module level with `@@reventless.consistency(AlwaysStrong)` (or
      `AlwaysEventual`). Affects RCU/latency only, never correctness — the
      conditional append's fence is always evaluated strongly. */
  let readConsistency: ReadConsistency.t
}

/**
The Behavior — pure state machine that decides commands and folds events.

`module Spec: Spec` shares the lean Spec's types so `evolve` references
`Spec.consumedEvent`, `decide` references `Spec.command`/`Spec.event`/`Spec.error`.
*/
module type Behavior = {
  module Spec: Spec

  /**
  The ephemeral state built by replaying relevant events.
  Not persisted — reconstructed for each command by reading from the DCB log.
  */
  type state

  /** The initial (empty) state before any events have been applied. */
  let initialState: state

  /**
  Folds one consumed event into the state during the read phase.
  Must be a pure function — no side effects.
  */
  let evolve: (state, Spec.consumedEvent) => state

  /**
  Decides what events to append given the current state and the command.
  Return `Ok(events)` to append, or `Error(error)` to reject the command.
  */
  let decide: (state, Spec.command) => result<array<Spec.event>, Spec.error>

  /** File URL of this Behavior module (`import.meta.url`). */
  let moduleUrl: string
}

