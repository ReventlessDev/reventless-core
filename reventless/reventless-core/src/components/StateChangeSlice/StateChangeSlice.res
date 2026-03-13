let componentType = ComponentType.StateChangeSlice

type t = ReventlessInfra.StateChangeSlice.t
type outputs = ReventlessInfra.StateChangeSlice.outputs
type operations = ReventlessInfra.StateChangeSlice.operations
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.StateChangeSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = Component.t<t, outputs, operations>

  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
