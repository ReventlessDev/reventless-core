let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDb.makeTable(
    name,
    ~attributes=[{name: "id", type_: "S"}, {name: "sequenceNr", type_: "S"}],
    ~rangeKey="sequenceNr",
    ~tags=AWS.Tags.make(~name, ReventlessCore.EventLog.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    operations: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable => {
      ReventlessCore.EventLog_Adapter.append: EventLogStorage_DynamoDb_Runtime.append(
        runtimeTable,
        ...
      ),
      replay: EventLogStorage_DynamoDb_Runtime.replay(runtimeTable, ...),
      replayStream: EventLogStorage_DynamoDb_Runtime.replayStream(runtimeTable, ...),
      appendStream: EventLogStorage_DynamoDb_Runtime.appendStream(runtimeTable, ...),
    }),
  }
}
