let make: Reventless.EventLog.Adapter.storageMaker = (~name, ~opts) => {
  let table = Util.DynamoDb.makeTable(
    name,
    ~attributes=[{"name": "id", "type": "S"}, {"name": "sequenceNr", "type": "S"}],
    ~rangeKey="sequenceNr",
    ~tags=[("Name", name), ("Type", "EventLog")]->Js.Dict.fromArray->Pulumi.Input.make,
    ~opts,
  )

  {
    resources: [table->Util_DynamoDb.toResource],
    append: table->EventLogStorage_DynamoDb_Runtime.append,
    replay: table->EventLogStorage_DynamoDb_Runtime.replay,
  }
}
