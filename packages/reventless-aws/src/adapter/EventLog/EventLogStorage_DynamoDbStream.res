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
    resources: [table->Util_DynamoDbStream.toResource],
    append: (sequenceNr, id, jsons) =>
      (table->EventLogStorage_DynamoDb_Runtime.append)(sequenceNr, id, jsons),
    replay: id => (table->EventLogStorage_DynamoDb_Runtime.replay)(id),
  }
}
