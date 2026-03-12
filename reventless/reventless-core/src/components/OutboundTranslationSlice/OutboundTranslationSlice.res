let componentType = ComponentType.OutboundTranslationSlice

type t
type outputs = ReventlessInfra.OutboundTranslationSlice.outputs
type operations = ReventlessInfra.OutboundTranslationSlice.operations
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.OutboundTranslationSlice.Spec
  type dcbEventLogComponent = DcbEventLog.component<DcbEventLog.operations<dcbEvent>>
  type component = Component.t<t, outputs, operations>
  let queryDbName: string

  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
