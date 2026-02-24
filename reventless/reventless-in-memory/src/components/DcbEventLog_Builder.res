// In-memory DcbEventLog builder.

module Make = (Bus: InMemory_Bus.T) => {
  module EventTopicPublisher = EventTopicPublisher_InMemory.Make(Bus)

  module Make = (
    Spec: ReventlessSpec.DcbEventLog.Spec,
  ) => {
    include Reventless.DcbEventLog_Builder.Make(Spec, DcbEventLogStorage_InMemory, EventTopicPublisher)
    // Re-shadow `operations` with spec-typed return so callers without reventless in scope
    // can resolve the Output chain (e.g. in beforeAllAsync to register handlers).
    let operations: component => Pulumi.Output.t<ReventlessSpec.DcbEventLog.operations<Spec.event>> =
      ReventlessSpec.Component.operations
  }
}
