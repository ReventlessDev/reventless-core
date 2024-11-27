let make: Reventless.EventLog.Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDb.makeTable(
    name,
    ~attributes=[{name: "id", type_: "S"}, {name: "sequenceNr", type_: "S"}],
    ~rangeKey="sequenceNr",
    ~tags=AWS.tags(~name, Reventless.EventLog.componentType),
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    append: (sequenceNr, id, jsons) =>
      (table->EventLogStorage_DynamoDb_Runtime.append)(sequenceNr, id, jsons),
    replay: id => (table->EventLogStorage_DynamoDb_Runtime.replay)(id),
  }
}
