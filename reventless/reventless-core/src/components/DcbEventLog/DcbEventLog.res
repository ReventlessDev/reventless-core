let componentType = ComponentType.DcbEventLog

type outputs = Reventless.DcbEventLog.outputs

type t
type component<'operations> = Component.t<t, outputs, 'operations>

type sequencedEvent<'event> = Reventless.DcbEventLog.sequencedEvent<'event>
type readResult<'event> = Reventless.DcbEventLog.readResult<'event>
type read<'event> = Reventless.DcbEventLog.read<'event>
type append<'event> = Reventless.DcbEventLog.append<'event>
type operations<'event> = Reventless.DcbEventLog.operations<'event>

module type T = {
  module Spec: Reventless.DcbEventLog.Spec

  type component = component<operations<Spec.event>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
