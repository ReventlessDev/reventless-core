let componentType = ComponentType.StateChangeSlice

type t
type outputs = ReventlessSpec.StateChangeSlice.outputs
type operations = ReventlessSpec.StateChangeSlice.operations
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: ReventlessSpec.StateChangeSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = Component.t<t, outputs, operations>

  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
