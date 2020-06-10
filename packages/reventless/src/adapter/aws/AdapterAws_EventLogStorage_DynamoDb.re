let make = (~name, ~opts) => {
  let tableName = name ++ "Table";
  let table =
    PulumiAws.DynamoDb.Table.make(
      ~name=tableName,
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

  EventLog.{
    resource: table->AdapterAws_Util_DynamoDb.toResource,
    append: table->AdapterAws_EventLogStorage_DynamoDb_Runtime.append,
    replay: table->AdapterAws_EventLogStorage_DynamoDb_Runtime.replay,
  };
};