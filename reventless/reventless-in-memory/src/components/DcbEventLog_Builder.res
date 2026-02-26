// In-memory DcbEventLog builder.

module Make = (Bus: InMemory_Bus.T) => {
  module EventTopicPublisher = EventTopicPublisher_InMemory.Make(Bus)

  module Make = (
    Spec: Reventless.DcbEventLog.Spec,
  ) => {
    include ReventlessCore.DcbEventLog_Builder.Make(Spec, DcbEventLogStorage_InMemory, EventTopicPublisher)
    // Re-shadow `operations` with spec-typed return so callers without reventless in scope
    // can resolve the Output chain (e.g. in beforeAllAsync to register handlers).
    let operations: component => Pulumi.Output.t<Reventless.DcbEventLog.operations<Spec.event>> =
      Reventless.Component.operations
  }
}
