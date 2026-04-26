// StateChangeSlice builder — no platform-specific adapters needed.

module Make = (Spec: Reventless.StateChangeSlice.MergedSpec) => {
  include ReventlessCore.StateChangeSlice_Builder.Make(Spec)
  // Re-shadow `make` with spec-typed publishJsons (transparent alias, avoids
  // callers needing reventless in scope to see ReventlessCore.CommandTopic.publishJsons).
  let make: (
    ~dcbEventLog: ReventlessInfra.DcbEventLog.component,
    ~publishJsons: Pulumi.Output.t<ReventlessInfra.CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = make
}
