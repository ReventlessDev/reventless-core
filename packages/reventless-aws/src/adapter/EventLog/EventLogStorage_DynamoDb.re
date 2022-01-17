let make: Reventless.EventLog.Adapter.storageMaker =
  (~name, ~opts, ~resources as _) => {
    let table =
      PulumiAws.DynamoDb.Table.(
        make(
          ~name,
          ~args=
            Args.make(
              ~attributes=
                [|
                  {"name": "id", "type": "S"},
                  {"name": "sequenceNr", "type": "S"},
                |]
                ->Pulumi.Input.wrap,
              ~hashKey="id"->Pulumi.Input.wrap,
              ~rangeKey="sequenceNr"->Pulumi.Input.wrap,
              ~billingMode=`PAY_PER_REQUEST,
              ~pointInTimeRecovery=
                Args.PointInTimeRecovery.make(~enabled=true)
                ->Pulumi.Input.wrap,
              (),
            ),
          ~opts,
          (),
        )
      );

    {
      resource: table->Util_DynamoDb.toResource,
      append: table->EventLogStorage_DynamoDb_Runtime.append,
      replay: table->EventLogStorage_DynamoDb_Runtime.replay,
    };
  };
