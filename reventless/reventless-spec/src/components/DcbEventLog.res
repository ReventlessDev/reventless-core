/**
Module type for a DCB (Distributed Command Behavior) event log specification.

A DCB event log is a shared, append-only log used by multiple `StateChangeSlice`
and `StateViewSlice` components. All slices that belong to the same log share
the same `event` union type.

@example
```rescript
// CatalogEventLog.res
@schema
type event =
  | ProductAdded({productId: @s.matches(DcbTag.string) string, name: string, description: string, price: float})
  | ProductNameUpdated({productId: @s.matches(DcbTag.string) string, name: string})
  | CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})
  | CategoryArchived({categoryId: @s.matches(DcbTag.string) string})
```
*/
module type Spec = {
  /** The union of all event types stored in this DCB event log. Must carry `@schema`. */
  @schema
  type event
}

/**
Module type produced by `Platform.DcbEventLog.Make(Spec)`.

@example
```rescript
// CatalogPlugin.res
module CatalogLog = Platform.DcbEventLog.Make(CatalogEventLog)
let log = CatalogLog.make(~name="CatalogEventLog")
```
*/
module type T = {
  module Spec: Spec
  type component
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}

/**
Deploy-time outputs produced when a `DcbEventLog` is provisioned.

- `resources` — the underlying storage infrastructure (e.g. DynamoDB table)
- `eventTopic` — the SNS topic for downstream subscribers (state view slices)
*/
type outputs = {resources: array<Adapter.resource>, eventTopic: EventTopic.outputs}

/**
A DCB event at a known position in the log, with its extracted content-based tags.

Returned by `read` and `readStream` operations.
*/
type sequencedEvent<'event> = {
  position: DcbTag.sequencePosition,
  event: 'event,
  tags: array<DcbTag.tag>,
}

/**
The result of a DCB `read` operation.

- `events` — the matching events in sequence order
- `headPosition` — the sequence position of the last event read (use as the
  `after` cursor in a subsequent `appendCondition` to detect conflicts)
*/
type readResult<'event> = {
  events: array<sequencedEvent<'event>>,
  headPosition?: DcbTag.sequencePosition,
}

/**
Reads events from the DCB log matching the given query.

- `~query` — content-based filter (event types + tags)
- `~after` — optional cursor; only events after this position are returned

@example
```rescript
// Read all Category events for "cat-1"
let result = await ops.read(
  ~query=[{
    eventTypes: ["CategoryAdded", "CategoryArchived"],
    tags: [{key: "categoryId", value: "cat-1"}],
  }],
)
let headPos = result.headPosition
```
*/
type read<'event> = (
  ~query: DcbTag.query,
  ~after: DcbTag.sequencePosition=?,
) => promise<readResult<'event>>

/**
Appends events to the DCB log with optional optimistic-concurrency checking.

Returns `Ok(position)` on success or `Error(reason)` if the append condition
was violated (i.e. the log was modified since `condition.after`).

@example
```rescript
// AddCategory.res — append only if category does not yet exist
let result = await ops.append(
  [CategoryAdded({categoryId: "cat-1", name: "Electronics"})],
  ~condition={
    query: [{eventTypes: ["CategoryAdded"], tags: [{key: "categoryId", value: "cat-1"}]}],
  },
)
switch result {
| Ok(pos) => Console.log2("Appended at", pos)
| Error(msg) => Console.error2("Conflict:", msg)
}
```
*/
type append<'event> = (
  array<'event>,
  ~condition: DcbTag.appendCondition=?,
) => promise<result<DcbTag.sequencePosition, string>>

/**
Streams events from the DCB log matching the given query.
Use for large result sets that should not be loaded into memory at once.
*/
type readStream<'event> = (
  ~query: DcbTag.query,
  ~after: DcbTag.sequencePosition=?,
) => Stream.t<sequencedEvent<'event>, string, unit>

/**
Appends a stream of events to the DCB log as an `Effect.t`.
Use for high-throughput batch imports.
*/
type appendStream<'event> = (
  Stream.t<'event, string, unit>,
  ~condition: DcbTag.appendCondition=?,
) => Effect.t<result<DcbTag.sequencePosition, string>, string, unit>

/**
Runtime operations exposed by a `DcbEventLog` component.

Obtained via `Component.operations(dcbEventLog)`. Available inside Lambda handlers.
*/
type operations<'event> = {
  read: read<'event>,
  append: append<'event>,
  readStream: readStream<'event>,
  appendStream: appendStream<'event>,
}
