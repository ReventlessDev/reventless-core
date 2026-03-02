/**
Module type for a DCB read-side state view slice specification.

A `StateViewSlice` is the DCB equivalent of a `ReadModel`: it listens to the
shared `DcbEventLog` event topic and projects events into a queryable state table
using the `Projection.action` algebra.

@example
```rescript
// CategoriesView.res
let name = "CategoriesView"
module DcbEventLogSpec = CatalogEventLog

@schema type event = CatalogEventLog.event
@schema type state = {categoryId: string, name: string, archived: bool}

let project = (_, event) => switch event {
  | CategoryAdded({categoryId, name}) =>
    [Set(categoryId, {categoryId, name, archived: false})]
  | CategoryRenamed({categoryId, name}) =>
    [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) =>
    [Update(categoryId, state => {...state, archived: true})]
  | _ => [] // Product events are not handled by this view
}
```
*/
module type Spec = {
  /** Logical name of this view slice (used as a DynamoDB table prefix). */
  let name: string

  /** The DCB event log spec this slice subscribes to. */
  module DcbEventLogSpec: DcbEventLog.Spec

  /**
  The subset of DCB events this slice cares about.
  Often set to `DcbEventLogSpec.event` to receive all events.
  Must carry `@schema`.
  */
  @schema
  type event

  /** The projected state type stored in the view table. Must carry `@schema`. */
  @schema
  type state

  /** Sury schema for the state type — generated automatically by `@schema`. */
  let stateSchema: S.t<state>

  /**
  Projects one DCB event into read model actions.

  - `option<state>` — the current state (`None` if the row does not exist yet)
  - `DcbEventLogSpec.event` — the incoming event from the shared log

  Return `[]` for events this slice does not care about.
  */
  let project: (option<state>, DcbEventLogSpec.event) => array<Projection.action<string, state>>
}
