let componentType = ComponentType.EventLog

type outputs = ReventlessSpec.EventLog.outputs

type t
type component<'operations> = Component.t<t, outputs, 'operations>

exception ReplayError(string)

type append<'id, 'event> = (int, 'id, array<'event>) => promise<result<unit, string>>
type replay<'id, 'event> = 'id => promise<array<'event>>

module type T = {
  module Spec: ReventlessSpec.EventLog.T

  type operations = {
    append: append<Spec.Id.t, Message.event'<Spec.Id.t, Spec.event>>,
    replay: replay<Spec.Id.t, Spec.event>,
  }
  type component = component<operations>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
