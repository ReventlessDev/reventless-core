let make: Reventless.EventLog.Adapter.storageMaker =
  (~name, ~opts, ~resources as _) => {
    let table =
      Util.DynamoDbStream.makeTable(
        name,
        ~attributes=[|
          {"name": "id", "type": "S"},
          {"name": "sequenceNr", "type": "S"},
        |],
        ~rangeKey="sequenceNr",
        ~opts,
      );

    {
      resource: table->Util_DynamoDbStream.toResource,
      append: table->EventLogStorage_DynamoDb_Runtime.append,
      replay: table->EventLogStorage_DynamoDb_Runtime.replay,
    };
  };
