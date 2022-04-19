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
        ~streamViewType=`NEW_IMAGE,
        ~opts,
      );

    {
      resources: [|table->Util_DynamoDbStream.toResource|],
      append: table->EventLogStorage_DynamoDb_Runtime.append,
      replay: table->EventLogStorage_DynamoDb_Runtime.replay,
    };
  };
