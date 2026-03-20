let componentType = ComponentType.InboundTranslationSlice

type t = ReventlessInfra.InboundTranslationSlice.t
type outputs = ReventlessInfra.InboundTranslationSlice.outputs
type operations = ReventlessInfra.InboundTranslationSlice.operations
type component = Component.t<t, outputs, operations>

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.InboundTranslationSlice.resolvedOutputs> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.InboundTranslationSlice.resolvedOutputs = {
      resources: resources,
      queryDb: {resources: queryDbResources},
    }
    resolved
  })

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
