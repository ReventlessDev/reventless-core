let componentType = ComponentType.AutomationSlice

type t = ReventlessInfra.AutomationSlice.t
type outputs = ReventlessInfra.AutomationSlice.outputs
type operations = ReventlessInfra.AutomationSlice.operations
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.AutomationSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = Component.t<t, outputs, operations>
  let queryDbName: string

  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
