let componentType = ComponentType.EventLog

type outputs = Reventless.EventLog.outputs

type t
type component<'operations> = Component.t<t, outputs, 'operations>

exception ReplayError(string)

type append<'id, 'event> = (int, 'id, array<'event>) => promise<result<unit, string>>
type replay<'id, 'event> = 'id => promise<array<'event>>
type replayStream<'id, 'event> = 'id => Stream.t<'event, string, unit>

module type T = {
  module Spec: Reventless.EventLog.T

  type operations = {
    append: append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: replay<Spec.Id.t, Spec.event>,
    replayStream: replayStream<Spec.Id.t, Spec.event>,
  }
  type component = component<operations>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
