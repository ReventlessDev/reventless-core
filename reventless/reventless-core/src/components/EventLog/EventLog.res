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

type append<'id, 'event> = (int, 'id, array<'event>) => promise<result<unit, appendError>>
type replay<'id, 'event> = 'id => promise<array<'event>>
type replayStream<'id, 'event> = 'id => Stream.t<'event, string, unit>
type appendStream<'id, 'event> = (int, 'id, Stream.t<'event, string, unit>) => Effect.t<unit, string, unit>

module type T = {
  module Spec: ReventlessInfra.EventLog.T

  type operations = {
    append: append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: replay<Spec.Id.t, Spec.event>,
    replayStream: replayStream<Spec.Id.t, Spec.event>,
    appendStream: appendStream<Spec.Id.t, Spec.event>,
  }
  type component = component<operations>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
