/**
Deploy-time outputs produced when a `DcbEventLog` is provisioned.

- `resources` — the underlying storage infrastructure (e.g. DynamoDB table)
- `eventTopic` — the SNS topic for downstream subscribers (state view slices)
*/
type outputs = {resources: array<Adapter.resource>, eventTopic: EventTopic.outputs}

/**
A raw event ready to be stored in the DCB log.
Produced by slice callbacks after encoding with their eventSchema.

`meta` is the envelope metadata for this event (causation, correlation, tracing).
Slice callbacks derive it from the triggering message's context.
*/
type rawEvent = {
  eventType: string,
  data: JSON.t,
  tags: array<Reventless.DcbTag.tag>,
  meta: Reventless.Message.meta,
}

/**
A raw event read from the DCB log at a known position.
Consumed by slice callbacks for decoding with their consumedEventSchema.

`meta` is the envelope metadata that was written at append time.
`recordedAt` is the storage timestamp, set by the storage adapter at append.
*/
type rawSequencedEvent = {
  position: Reventless.DcbTag.sequencePosition,
  eventType: string,
  data: JSON.t,
  tags: array<Reventless.DcbTag.tag>,
  meta: Reventless.Message.meta,
  recordedAt: string,
}

/**
The result of a DCB `read` operation.

- `events` — the matching events in sequence order
- `headPosition` — the sequence position of the last event read (use as the
  `after` cursor in a subsequent `appendCondition` to detect conflicts)
*/
type readResult = {
  events: array<rawSequencedEvent>,
  headPosition?: Reventless.DcbTag.sequencePosition,
}

/**
Reads events from the DCB log matching the given query.

- `~query` — content-based filter (event types + tags)
- `~after` — optional cursor; only events after this position are returned
*/
type read = (
  ~query: Reventless.DcbTag.query,
  ~after: Reventless.DcbTag.sequencePosition=?,
) => promise<readResult>

/**
Appends raw events to the DCB log with optional optimistic-concurrency checking.

Returns `Ok(position)` on success or `Error(reason)` if the append condition
was violated (i.e. the log was modified since `condition.after`).
*/
type append = (
  array<rawEvent>,
  ~condition: Reventless.DcbTag.appendCondition=?,
) => promise<result<Reventless.DcbTag.sequencePosition, string>>

/**
Streams events from the DCB log matching the given query.
Use for large result sets that should not be loaded into memory at once.
*/
type readStream = (
  ~query: Reventless.DcbTag.query,
  ~after: Reventless.DcbTag.sequencePosition=?,
  /** Opt into strongly-consistent single-tag reads. Defaults to eventually
      consistent: a stale read can only cause a rejected append (then a retry),
      never a wrong write, because the append fence is always evaluated strongly.
      The slice callback sets this on retries (eventual-first, strong-on-retry). */
  ~strongConsistency: bool=?,
) => Stream.t<rawSequencedEvent, string, unit>

/**
Appends a stream of raw events to the DCB log as an `Effect.t`.
Use for high-throughput batch imports.
*/
type appendStream = (
  Stream.t<rawEvent, string, unit>,
  ~condition: Reventless.DcbTag.appendCondition=?,
) => Effect.t<result<Reventless.DcbTag.sequencePosition, string>, string, unit>

/**
Runtime operations exposed by a `DcbEventLog` component.
Works with raw events — encode/decode is handled by each slice's callback.

Obtained via `Component.operations(dcbEventLog)`. Available inside Lambda handlers.
*/
type operations = {
  read: read,
  append: append,
  readStream: readStream,
  appendStream: appendStream,
}

type t
type component = Component.t<t, outputs, operations>

module type T = {
  type component = component
  let make: (~name: string, ~indexes: array<string>=?, ~opts: Pulumi.ComponentResource.options=?) => component
}
