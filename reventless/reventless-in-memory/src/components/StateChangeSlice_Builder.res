// StateChangeSlice builder — no platform-specific adapters needed.

module Make = (Spec: ReventlessSpec.StateChangeSlice.Spec) => {
  include Reventless.StateChangeSlice_Builder.Make(Spec)
  // Re-shadow `make` with spec-typed publishJsons (transparent alias, avoids
  // callers needing reventless in scope to see Reventless.CommandTopic.publishJsons).
  let make: (
    ~dcbEventLog: dcbEventLogComponent,
    ~publishJsons: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = make
}
