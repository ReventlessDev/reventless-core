let componentType = ComponentType.StateViewSlice

type t
type outputs = ReventlessSpec.StateViewSlice.outputs
type operations = ReventlessSpec.StateViewSlice.operations
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: ReventlessSpec.StateViewSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = Component.t<t, outputs, operations>

  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
