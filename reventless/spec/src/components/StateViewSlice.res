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

@example
```rescript
// CategoriesView.res
let name = "CategoriesView"

@schema type state = {categoryId: string, name: string, archived: bool}

@schema type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

let project = ({event}) => switch event {
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

  /** Authorization rule evaluated at the GraphQL resolver entry before any
      query is resolved. Auto-injected by `@@reventless.spec` and on
      structurally-detected inline spec modules — defaults to
      `AllowAuthenticated`. */
  let authorization: Authorization.permission

  /** AutoUI visibility hint. Auto-injected by `@@reventless.spec` and on
      structurally-detected inline spec modules — defaults to
      `Visibility.Public`; override at the file/module level with
      `@@reventless.visibility(Internal)` to hide from the AutoUI manifest.
      Does not affect GraphQL exposure, authorization, or resolver
      provisioning. */
  let visibility: Visibility.t
}

/**
The envelope a projection receives for each consumed event.

Carries the decoded event alongside the metadata the storage layer already
holds, so a projection can persist producer time or the acting user without the
command author having to duplicate that framework state into the event payload.

`meta.time` and `recordedAt` are **different clocks** — pick deliberately:

- `meta.time` — *producer* time, stamped when the command handler created the
  event. This is the domain-meaningful timestamp (when the order was placed,
  when it shipped); it is identical across every path.
- `recordedAt` — *storage* time, when the event was appended to the DCB log. On
  the AWS (DynamoDB-stream) path this is the authoritative stored column; on the
  local (topic) path it is stamped at publish, so it may sit a few milliseconds
  after the stored value. Use it for storage-lag diagnostics, not domain dates.
*/
type consumed<'e> = {
  event: 'e,
  meta: Message.meta,
  recordedAt: string,
}

/**
The Projection — the pure projection function from consumed events to actions.
*/
module type Projection = {
  module Spec: Spec

  /**
  Projects one consumed event into read model actions.
  Receives the event wrapped in a `consumed` envelope (event + `meta` +
  `recordedAt`); only events declared in `Spec.consumedEvent` — no wildcard needed.
  */
  let project: consumed<Spec.consumedEvent> => array<Projection.action<string, Spec.state>>

  /** File URL of this Projection module (`import.meta.url`). */
  let moduleUrl: string
}

