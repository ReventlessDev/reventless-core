let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name, ~owner=?, ~opts) => {
  let tags = AWS.Tags.make(~name, ~kind=ReventlessCore.EventLog.componentType, ~role=EventLog, ~owner?)
  let table = Util.DynamoDb.makeTable(
    name,
    ~attributes=[{name: "id", type_: "S"}, {name: "position", type_: "S"}],
    ~rangeKey="position",
    ~tags,
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource(~tags=tags->Pulumi.Output.fromInput)],
    operations: table
    ->Util_DynamoDb.toResolvedTableOutput
    ->Pulumi.Output.apply(resolvedTable => {
      ReventlessCore.EventLog_Adapter.append: EventLogStorage_DynamoDb_Runtime.append(
        resolvedTable,
        ...
      ),
      replay: EventLogStorage_DynamoDb_Runtime.replay(resolvedTable, ...),
      replayStream: EventLogStorage_DynamoDb_Runtime.replayStream(resolvedTable),
      appendStream: EventLogStorage_DynamoDb_Runtime.appendStream(resolvedTable, ...),
      latestSnapshot: EventLogStorage_DynamoDb_Runtime.latestSnapshot(resolvedTable),
      writeSnapshot: EventLogStorage_DynamoDb_Runtime.writeSnapshot(resolvedTable),
    }),
  }
}
