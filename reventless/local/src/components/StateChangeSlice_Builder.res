// StateChangeSlice builder — no platform-specific adapters needed.

module Make = (
  Spec: Reventless.StateChangeSlice.Spec,
  Decision: Reventless.StateChangeSlice.Decision with module Spec := Spec,
) => {
  module Inner = ReventlessCore.StateChangeSlice_Builder.Make(Spec, Decision)
  module Spec = Spec
  module Decision = Decision
  let isAsync = Inner.isAsync
  type component = Inner.component
  let make: (
    ~dcbEventLog: ReventlessInfra.DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<ReventlessInfra.CommandTopic.publishJsons>,
    ~tagKeysByEventType: Dict.t<array<string>>=?,
    ~crossPartitionTagKeys: array<string>=?,
    ~partitionTag: Reventless.DcbTag.derivedPartitionTag=?,
    ~runtime: ReventlessInfra.RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = Inner.make
}
