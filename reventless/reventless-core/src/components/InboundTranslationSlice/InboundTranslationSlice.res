let componentType = ComponentType.InboundTranslationSlice

type t = ReventlessInfra.InboundTranslationSlice.t
type outputs = ReventlessInfra.InboundTranslationSlice.outputs
type operations = ReventlessInfra.InboundTranslationSlice.operations
type component = Component.t<t, outputs, operations>

module type T = {
  type dcbEvent
  module Spec: Reventless.InboundTranslationSlice.Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string

  let make: (
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
