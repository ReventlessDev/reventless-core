let componentType = ComponentType.StateChangeSlice

type t
type outputs = {
  resources: array<ReventlessSpec.Adapter.resource>,
}
type operations = {publishJsons: CommandTopic.publishJsons}
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: ReventlessSpec.StateChangeSlice_Spec.T

  let make: (
    ~dcbEventLog: DcbEventLog.component<DcbEventLog.operations<dcbEvent>>,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
