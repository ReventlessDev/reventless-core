let componentType = ComponentType.EventLog

type outputs = ReventlessInfra.EventLog.outputs

type t
type component<'operations> = Component.t<t, outputs, 'operations>

exception ReplayError(string)

// Typed append outcome. `Conflict` is the optimistic-concurrency sentinel — the
// deliberate append-condition failure (seq_nr/position already taken) that the
// caller retries by re-reading and re-deciding. Every other failure is a
// `StorageFailure` carrying its message. This replaces the former string sentinel
// that was detected by substring-matching a pretty-printed Cause across three
// layers — a real error whose text happened to contain "conflict" would have
// been retried as an OCC conflict, and a misclassified conflict would surface as
// a permanent error.
type appendError =
  | Conflict
  | StorageFailure(string)

// A persisted aggregate-state snapshot: `state` is the fold of events
// seq 0..seqNr-1, so `seqNr` doubles as the sequence number to resume the
// replay from (and the OCC condition for the next append). `schemaHash` gates
// staleness — consumers ignore a snapshot whose hash differs from their current
// state schema and fall back to full replay. Snapshots are a read optimization
// only; the OCC append remains the sole consistency primitive
// (docs/plans/done/aggregate-snapshotting.md).
type snapshot = {seqNr: int, state: JSON.t, schemaHash: string}

type append<'id, 'event> = (int, 'id, array<'event>) => promise<result<unit, appendError>>
type replay<'id, 'event> = 'id => promise<array<'event>>
// `fromSeq` starts the replay at that sequence number (inclusive; default 0) —
// the delta read after seeding from a snapshot at seqNr = fromSeq.
type replayStream<'id, 'event> = ('id, ~fromSeq: int=?) => Stream.t<'event, string, unit>
type appendStream<'id, 'event> = (int, 'id, Stream.t<'event, string, unit>) => Effect.t<unit, string, unit>
// Keep-one semantics: `writeSnapshot` overwrites the single snapshot per
// aggregate; recovery from a corrupt snapshot is full replay, not older
// snapshots. Failures are plain strings — a snapshot op failure must never
// fail a command, so no retryable/typed error channel is needed.
type latestSnapshot<'id> = 'id => promise<result<option<snapshot>, string>>
type writeSnapshot<'id> = ('id, snapshot) => promise<result<unit, string>>

module type T = {
  module Spec: ReventlessInfra.EventLog.T

  type operations = {
    append: append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: replay<Spec.Id.t, Spec.event>,
    replayStream: replayStream<Spec.Id.t, Spec.event>,
    appendStream: appendStream<Spec.Id.t, Spec.event>,
    latestSnapshot: latestSnapshot<Spec.Id.t>,
    writeSnapshot: writeSnapshot<Spec.Id.t>,
  }
  type component = component<operations>

  let make: (
    ~name: string,
    ~owner: ResourceAttribution.owner=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
