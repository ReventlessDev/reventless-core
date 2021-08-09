let make: Reventless.EventLog.Adapter.storageMaker =
  (~name, ~opts) => {
    let table =
      PulumiAws.DynamoDb.Table.make(
        ~name,
        ~args=
          PulumiAws.DynamoDb.Table.Args.make(
            ~attributes=
              [|
                {"name": "id", "type": "S"},
                {"name": "sequenceNr", "type": "S"},
              |]
              ->Pulumi.Input.wrap,
            ~hashKey="id"->Pulumi.Input.wrap,
            ~rangeKey="sequenceNr"->Pulumi.Input.wrap,
            ~billingMode=`PAY_PER_REQUEST,
            ~streamEnabled=true,
            ~streamViewType=`NEW_IMAGE,
            (),
          ),
        ~opts,
        (),
      );

    {
      resource: table->Util_DynamoDb.toResource,
      append: table->EventLogStorage_DynamoDb_Runtime.append,
      replay: table->EventLogStorage_DynamoDb_Runtime.replay,
    };
  };
