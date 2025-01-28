let make: Reventless.EventLog.Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDbStream.makeTable(
    name,
    ~attributes=[{name: "id", type_: "S"}, {name: "sequenceNr", type_: "S"}],
    ~rangeKey="sequenceNr",
    ~streamViewType=NEW_IMAGE,
    ~tags=AWS.tags(~name, Reventless.EventLog.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    append: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable =>
      EventLogStorage_DynamoDb_Runtime.append(runtimeTable, ...)
    ),
    replay: table
    ->Util_DynamoDb.toRuntimeTableOutput
    ->Pulumi.Output.apply(runtimeTable =>
      EventLogStorage_DynamoDb_Runtime.replay(runtimeTable, ...)
    ),
  }
}
