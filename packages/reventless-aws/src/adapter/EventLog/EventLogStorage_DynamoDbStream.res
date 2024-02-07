let make: Reventless.EventLog.Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDbStream.makeTable(
    name,
    ~attributes=[{"name": "id", "type": "S"}, {"name": "sequenceNr", "type": "S"}],
    ~rangeKey="sequenceNr",
    ~streamViewType=#NEW_IMAGE,
    ~tags=[("Name", name), ("Type", "EventLog")]->Js.Dict.fromArray->Pulumi.Input.make,
    ~opts,
  )

  {
    resources: [table->Util_DynamoDbStream.toResource],
    append: table->EventLogStorage_DynamoDb_Runtime.append,
    replay: table->EventLogStorage_DynamoDb_Runtime.replay,
  }
}
