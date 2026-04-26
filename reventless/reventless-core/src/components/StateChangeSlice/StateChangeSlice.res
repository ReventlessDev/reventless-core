let componentType = ComponentType.StateChangeSlice

type t = ReventlessInfra.StateChangeSlice.t
type outputs = ReventlessInfra.StateChangeSlice.outputs
type operations = ReventlessInfra.StateChangeSlice.operations
type component = Component.t<t, outputs, operations>

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.StateChangeSlice.resolvedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToInterop
  ->Pulumi.Output.apply(resources => {
    let resolved: ReventlessInterop.StateChangeSlice.resolvedOutputs = {resources: resources}
    resolved
  })

module type T = {
  module Spec: Reventless.StateChangeSlice.Spec
  module Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec
  /** `true` when built with `Platform.StateChangeSlice.MakeAsync` — uses FIFO channel, returns `CommandPending`. */
  let isAsync: bool
  type component = Component.t<t, outputs, operations>

  let make: (
    ~dcbEventLog: DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
