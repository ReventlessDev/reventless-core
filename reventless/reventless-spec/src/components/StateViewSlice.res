/**
Module type for a DCB read-side state view slice specification.

A `StateViewSlice` is the DCB equivalent of a `ReadModel`: it listens to the
shared `DcbEventLog` event topic and projects events into a queryable state table
using the `Projection.action` algebra.

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
