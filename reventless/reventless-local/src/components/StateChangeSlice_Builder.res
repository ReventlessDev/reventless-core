// StateChangeSlice builder — no platform-specific adapters needed.

module Make = (
  Spec: Reventless.StateChangeSlice.Spec,
  Behavior: Reventless.StateChangeSlice.Behavior with module Spec := Spec,
) => {
  module Inner = ReventlessCore.StateChangeSlice_Builder.Make(Spec, Behavior)
  module Spec = Spec
  module Behavior = Behavior
  let isAsync = Inner.isAsync
  type component = Inner.component
  let make: (
    ~dcbEventLog: ReventlessInfra.DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<ReventlessInfra.CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = Inner.make
}
