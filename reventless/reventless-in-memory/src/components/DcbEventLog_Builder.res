// In-memory DcbEventLog builder.

module Make = (Bus: InMemory_Bus.T) => {
  module EventTopicPublisher = EventTopicPublisher_InMemory.Make(Bus)

  module Inner = ReventlessCore.DcbEventLog_Builder.Make(DcbEventLogStorage_InMemory, EventTopicPublisher)
  type component = ReventlessInfra.DcbEventLog.component
  let make: (
    ~name: string,
    ~indexes: array<string>=?,
    ~partitionTag: Reventless.DcbTag.partitionTag,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = Inner.make->Obj.magic
  // Expose `operations` so callers can resolve the Output chain
  // (e.g. in beforeAllAsync to register handlers).
  let operations: component => Pulumi.Output.t<ReventlessInfra.DcbEventLog.operations> =
    ReventlessInfra.Component.operations
}
