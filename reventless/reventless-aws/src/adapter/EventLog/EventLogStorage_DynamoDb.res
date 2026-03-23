let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDb.makeTable(
    name,
    ~attributes=[{name: "id", type_: "S"}, {name: "seq", type_: "S"}],
    ~rangeKey="seq",
    ~tags=AWS.Tags.make(~name, ReventlessCore.EventLog.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    operations: table
    ->Util_DynamoDb.toResolvedTableOutput
    ->Pulumi.Output.apply(resolvedTable => {
      ReventlessCore.EventLog_Adapter.append: EventLogStorage_DynamoDb_Runtime.append(
        resolvedTable,
        ...
      ),
      replay: EventLogStorage_DynamoDb_Runtime.replay(resolvedTable, ...),
      replayStream: EventLogStorage_DynamoDb_Runtime.replayStream(resolvedTable, ...),
      appendStream: EventLogStorage_DynamoDb_Runtime.appendStream(resolvedTable, ...),
    }),
  }
}
