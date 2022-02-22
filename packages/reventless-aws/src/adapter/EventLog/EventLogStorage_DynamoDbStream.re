let make: Reventless.EventLog.Adapter.storageMaker =
  (~name, ~opts, ~resources as _) => {
    let restoreSourceName =
      Pulumi.Config.make(Some("restore"))
      ->Pulumi.Config.getObject("tables")
      ->Belt.Option.flatMap(tables => tables->Js.Dict.get(name));
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
              ~streamEnabled=true,
              ~streamViewType=`NEW_IMAGE,
              ~pointInTimeRecovery=
                Args.PointInTimeRecovery.make(~enabled=true)
                ->Pulumi.Input.wrap,
              ~restoreSourceName=?
                restoreSourceName->Belt.Option.map(Pulumi.Input.wrap),
              ~restoreDateTime=?
                restoreSourceName->Belt.Option.flatMap(_ =>
                  Reventless.Env.restoreDateTime->Belt.Option.map(
                    Pulumi.Input.wrap,
                  )
                ),
              ~restoreToLatestTime=?
                restoreSourceName->Belt.Option.map(_ =>
                  Reventless.Env.restoreDateTime
                  ->Belt.Option.isNone
                  ->Pulumi.Input.wrap
                ),
              (),
            ),
          ~opts,
          (),
        )
      );

    {
      resource: table->Util_DynamoDbStream.toResource,
      append: table->EventLogStorage_DynamoDb_Runtime.append,
      replay: table->EventLogStorage_DynamoDb_Runtime.replay,
    };
  };
