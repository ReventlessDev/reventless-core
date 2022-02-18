let make: Reventless.EventLog.Adapter.storageMaker =
  (~name, ~opts, ~resources as _) => {
    let restoreConfig = Pulumi.Config.make(Some("restore"));
    let restoreSourceName =
      restoreConfig
      ->Pulumi.Config.getObject("tables")
      ->Belt.Option.flatMap(tables => tables->Js.Dict.get(name));
    let restoreDateTime = restoreConfig->Pulumi.Config.get("time");
    let restoreToLatestTime = restoreDateTime->Belt.Option.isNone;

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
              ~restoreSourceName=?
                restoreSourceName->Belt.Option.map(Pulumi.Input.wrap),
              ~restoreDateTime=?
                restoreDateTime->Belt.Option.map(Pulumi.Input.wrap),
              ~restoreToLatestTime=restoreToLatestTime->Pulumi.Input.wrap,
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
