let componentType = ComponentType.StateViewSlice

type t = ReventlessInfra.StateViewSlice.t
type outputs = ReventlessInfra.StateViewSlice.outputs
type operations = ReventlessInfra.StateViewSlice.operations
type component = Component.t<t, outputs, operations>

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.StateViewSlice.resolvedOutputs> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb.resources->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.StateViewSlice.resolvedOutputs = {
      resources: resources,
      queryDb: {resources: queryDbResources},
    }
    resolved
  })

module type T = {
  module Spec: Reventless.StateViewSlice.Spec
  module Projection: Reventless.StateViewSlice.Projection with module Spec := Spec
  type component = Component.t<t, outputs, operations>

  let make: (
    ~dcbEventLog: DcbEventLog.component,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
