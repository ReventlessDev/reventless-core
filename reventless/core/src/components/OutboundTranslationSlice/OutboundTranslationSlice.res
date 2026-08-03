let componentType = ComponentType.OutboundTranslationSlice

type t = ReventlessInfra.OutboundTranslationSlice.t
type outputs = ReventlessInfra.OutboundTranslationSlice.outputs
type operations = ReventlessInfra.OutboundTranslationSlice.operations
type component = Component.t<t, outputs, operations>

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.OutboundTranslationSlice.resolvedOutputs> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.OutboundTranslationSlice.resolvedOutputs = {
      resources: resources,
      queryDb: {resources: queryDbResources},
    }
    resolved
  })

module type T = {
  module Spec: Reventless.OutboundTranslationSlice.Spec
  module Translation: Reventless.OutboundTranslationSlice.Translation with module Spec := Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string

  let make: (
    ~dcbEventLog: DcbEventLog.component,
    ~allEventTopics: EventTopic.allOutputs=?,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~runtime: ReventlessInfra.RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
