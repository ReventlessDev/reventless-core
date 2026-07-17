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
    ~tagKeysByEventType: Dict.t<array<string>>=?,
    ~crossPartitionTagKeys: array<string>=?,
    ~runtime: ReventlessInfra.RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = Inner.make
}
