// In-memory DcbEventLog builder.

module Make = (Bus: LocalBus.T) => {
  module EventTopicPublisher = LocalEventTopicPublisher.Make(Bus)

  // Use the backend-aware storage functor (as Platform does), not the plain
  // module: the functor consults BackendState so a standalone DCB log honours
  // REVENTLESS_LOCAL_BACKEND=sqlite, and it registers the read with the Bus so
  // `Bus.getDcbEventLogRead` can see it. The plain module did neither — the log
  // silently stayed in memory under SQLite and was invisible to bus readers.
  module Storage = LocalDcbEventLogStorage.Make(Bus)
  module Inner = ReventlessCore.DcbEventLog_Builder.Make(Storage, EventTopicPublisher)
  type component = ReventlessInfra.DcbEventLog.component
  let make: (
    ~name: string,
    ~indexes: array<string>=?,
    ~partitionTag: Reventless.DcbTag.derivedPartitionTag,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component = Inner.make->Obj.magic
  // Expose `operations` so callers can resolve the Output chain
  // (e.g. in beforeAllAsync to register handlers).
  let operations: component => Pulumi.Output.t<ReventlessInfra.DcbEventLog.operations> =
    ReventlessInfra.Component.operations
}
