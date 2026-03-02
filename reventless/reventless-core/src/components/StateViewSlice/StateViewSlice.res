let componentType = ComponentType.StateViewSlice

type t
type outputs = ReventlessInfra.StateViewSlice.outputs
type operations = ReventlessInfra.StateViewSlice.operations
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.StateViewSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = Component.t<t, outputs, operations>

  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
