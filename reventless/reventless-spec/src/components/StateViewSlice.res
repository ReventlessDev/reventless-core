/**
Module types for a DCB read-side state view slice.

A `StateViewSlice` is the DCB equivalent of a `ReadModel`: it listens to the
shared `DcbEventLog` event topic and projects events into a queryable state table
using the `Projection.action` algebra.

Plan 02 splits the merged spec into two module types:

- `Spec` — types, identity, schemas, infrastructure config. The persisted
  state contract (matches the ReadModel convention where `state` is in Spec).
- `Projection` — the single `project` function (and any future projection
  helpers).

`MergedSpec` is the legacy combined shape kept for transitional use during
Phases 1–2 of the Spec-First migration.

@example
```rescript
// CategoriesView.res
let name = "CategoriesView"

@schema type state = {categoryId: string, name: string, archived: bool}

@schema type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

let project = event => switch event {
  | CategoryAdded({categoryId, name}) =>
    [Set(categoryId, {categoryId, name, archived: false})]
  | CategoryRenamed({categoryId, name}) =>
    [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) =>
    [Update(categoryId, state => {...state, archived: true})]
}
```
*/

/**
The lean Spec for a StateViewSlice — types, identity, schemas, infra config.
Per D2, `state` lives here (not in `Projection`) because the projected state
is the externally-observable contract — schema queried by GraphQL resolvers.
*/
module type Spec = {
  /** Logical name of this view slice (used as a DynamoDB table prefix). */
  let name: string
  let moduleUrl: string

  /** The projected state type stored in the view table. Must carry `@schema`. */
  @schema
  type state

  /** Sury schema for the state type — generated automatically by `@schema`. */
  let stateSchema: S.t<state>

  /**
  Events this view slice projects. Only needs the fields required for the projection —
  no tag annotations needed. May be payload-less where only existence matters.
  Must carry `@schema`.
  */
  @schema
  type consumedEvent

  /** Infrastructure configuration (indexes, resolvers). */
  let config: ReadModel.config

  /** Optional composite-key configuration. `None` for single-key tables. */
  let subIdConfig: option<ReadModel.subIdConfig<state>>
}

/**
The Projection — the pure projection function from consumed events to actions.
*/
module type Projection = {
  module Spec: Spec

  /**
  Projects one consumed event into read model actions.
  Receives only events declared in `Spec.consumedEvent` — no wildcard needed.
  */
  let project: Spec.consumedEvent => array<Projection.action<string, Spec.state>>

  /** File URL of this Projection module (`import.meta.url`). */
  let moduleUrl: string
}

/**
Legacy combined-shape module type. Bundles the lean Spec's types/schemas/config
with Projection's `project` function in a single module signature.

Used by slice builders pre-Phase 2; removed in Phase 6.
*/
module type MergedSpec = {
  /** Logical name of this view slice (used as a DynamoDB table prefix). */
  let name: string
  let moduleUrl: string

  /** The projected state type stored in the view table. Must carry `@schema`. */
  @schema
  type state

  /** Sury schema for the state type — generated automatically by `@schema`. */
  let stateSchema: S.t<state>

  /**
  Events this view slice projects. Only needs the fields required for the projection —
  no tag annotations needed. May be payload-less where only existence matters.
  Must carry `@schema`.
  */
  @schema
  type consumedEvent

  /**
  Projects one consumed event into read model actions.
  Receives only events declared in `consumedEvent` — no wildcard needed.
  */
  let project: consumedEvent => array<Projection.action<string, state>>

  /** Infrastructure configuration (indexes, resolvers). */
  let config: ReadModel.config

  /** Optional composite-key configuration. `None` for single-key tables. */
  let subIdConfig: option<ReadModel.subIdConfig<state>>
}
