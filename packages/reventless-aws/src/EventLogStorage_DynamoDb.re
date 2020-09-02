let make = (~name, ~opts) => {
  let table =
    PulumiAws.DynamoDb.Table.make(
      ~name,
      ~args=
        PulumiAws.DynamoDb.Table.Args.make(
          ~attributes=[|
            {"name": "id", "type": "S"},
            {"name": "sequenceNr", "type": "S"},
          |],
          ~hashKey="id",
          ~rangeKey="sequenceNr",
          ~billingMode=`PAY_PER_REQUEST,
          (),
        ),
      ~opts,
      (),
    );

  Reventless.EventLog.{
    resource: table->Util_DynamoDb.toResource,
    append: table->EventLogStorage_DynamoDb_Runtime.append,
    replay: table->EventLogStorage_DynamoDb_Runtime.replay,
  };
};
