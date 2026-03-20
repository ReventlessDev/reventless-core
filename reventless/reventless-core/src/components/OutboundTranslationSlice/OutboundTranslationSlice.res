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
