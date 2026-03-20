let componentType = ComponentType.AutomationSlice

type t = ReventlessInfra.AutomationSlice.t
type outputs = ReventlessInfra.AutomationSlice.outputs
type operations = ReventlessInfra.AutomationSlice.operations
type component = Component.t<t, outputs, operations>

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.AutomationSlice.resolvedOutputs> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.AutomationSlice.resolvedOutputs = {
      resources: resources,
      queryDb: {resources: queryDbResources},
    }
    resolved
  })

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
