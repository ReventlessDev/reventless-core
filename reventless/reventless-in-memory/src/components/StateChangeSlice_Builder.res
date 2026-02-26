// StateChangeSlice builder — no platform-specific adapters needed.

module Make = (Spec: Reventless.StateChangeSlice.Spec) => {
  include ReventlessCore.StateChangeSlice_Builder.Make(Spec)
  // Re-shadow `make` with spec-typed publishJsons (transparent alias, avoids
  // callers needing reventless in scope to see ReventlessCore.CommandTopic.publishJsons).
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<Reventless.CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = make
}
