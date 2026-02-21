let componentType = ComponentType.DcbEventLog

type outputs = ReventlessSpec.DcbEventLog.outputs

type t
type component<'operations> = Component.t<t, outputs, 'operations>

type sequencedEvent<'event> = ReventlessSpec.DcbEventLog.sequencedEvent<'event>
type readResult<'event> = ReventlessSpec.DcbEventLog.readResult<'event>
type read<'event> = ReventlessSpec.DcbEventLog.read<'event>
type append<'event> = ReventlessSpec.DcbEventLog.append<'event>
type operations<'event> = ReventlessSpec.DcbEventLog.operations<'event>

module type T = {
  module Spec: ReventlessSpec.DcbEventLog.Spec

  type component = component<operations<Spec.event>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
