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
  position: Reventless.DcbTag.sequencePosition,
  event: 'event,
  tags: array<Reventless.DcbTag.tag>,
}

/**
The result of a DCB `read` operation.

- `events` — the matching events in sequence order
- `headPosition` — the sequence position of the last event read (use as the
  `after` cursor in a subsequent `appendCondition` to detect conflicts)
*/
type readResult<'event> = {
  events: array<sequencedEvent<'event>>,
  headPosition?: Reventless.DcbTag.sequencePosition,
}

/**
Reads events from the DCB log matching the given query.

- `~query` — content-based filter (event types + tags)
- `~after` — optional cursor; only events after this position are returned
*/
type read<'event> = (
  ~query: Reventless.DcbTag.query,
  ~after: Reventless.DcbTag.sequencePosition=?,
) => promise<readResult<'event>>

/**
Appends events to the DCB log with optional optimistic-concurrency checking.

Returns `Ok(position)` on success or `Error(reason)` if the append condition
was violated (i.e. the log was modified since `condition.after`).
*/
type append<'event> = (
  array<'event>,
  ~condition: Reventless.DcbTag.appendCondition=?,
) => promise<result<Reventless.DcbTag.sequencePosition, string>>

/**
Streams events from the DCB log matching the given query.
Use for large result sets that should not be loaded into memory at once.
*/
type readStream<'event> = (
  ~query: Reventless.DcbTag.query,
  ~after: Reventless.DcbTag.sequencePosition=?,
) => Stream.t<sequencedEvent<'event>, string, unit>

/**
Appends a stream of events to the DCB log as an `Effect.t`.
Use for high-throughput batch imports.
*/
type appendStream<'event> = (
  Stream.t<'event, string, unit>,
  ~condition: Reventless.DcbTag.appendCondition=?,
) => Effect.t<result<Reventless.DcbTag.sequencePosition, string>, string, unit>

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

type t
type component<'operations> = Component.t<t, outputs, 'operations>

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
  module Spec: Reventless.DcbEventLog.Spec
  type component = component<operations<Spec.event>>
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
