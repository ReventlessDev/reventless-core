let toInfo = (table: PulumiAws.DynamoDb.Table.t) =>
  (table##hashKey, table##rangeKey)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((hashKey, rangeKey)) =>
      hashKey ++ "," ++ rangeKey->Belt.Option.getWithDefault("")
    );

let toResource = (table: PulumiAws.DynamoDb.Table.t) =>
  Reventless.Adapter.resource(
    ~service=
      table##name->Pulumi.Output.apply(_ => Util_DynamoDb_Runtime.service),
    ~name=table##name,
    ~id=table##id,
    ~urn=table##arn,
    ~info=table->toInfo,
  );

let arn2tableName = arn =>
  switch (arn->Js.String2.split(":")) {
  | [|_, _, _service, _region, _account, tableName|] => tableName
  | _ => Js.Exn.raiseError("Invalid ARN: " ++ arn)
  };

// Workaround when restore enabled: turn on ttl & pointInTimeRecovery again
open PulumiAws.DynamoDb.Table;

let enableTtl: string => Js.Promise.t(PulumiAws.DynamoDb.Table.TableTtl.t) =
  tableName => {
    Js.log({j|$__MODULE__: enableTimeToLive for $tableName|j});
    AwsSdk.DynamoDb_DynamoDb.(
      updateTimeToLive(
        UpdateTimeToLiveInput.make(
          ~_TableName=tableName,
          ~_TimeToLiveSpecification=
            TimeToLiveSpecification.make(
              ~_Enabled=true,
              ~_AttributeName=Util_DynamoDb_Runtime.purgeTimeAttributeName,
            ),
        ),
      )
    )
    ->Js.Promise.then_(
        res =>
          TableTtl.make(
            ~enabled=Some(res##_TimeToLiveSpecification##_Enabled),
            ~attributeName=res##_TimeToLiveSpecification##_AttributeName,
          )
          ->Js.Promise.resolve,
        _,
      );
  };

let verifyTtl:
  (~expectedTtl: int=?, table) =>
  Pulumi.Output.t(PulumiAws.DynamoDb.Table.TableTtl.t) =
  (~expectedTtl=?, table) =>
    (table##name, table##ttl)
    ->Pulumi.Output.all2
    ->Pulumi.Output.flatMap(((tableName, ttl)) =>
        (
          switch (ttl##enabled, expectedTtl) {
          | (None, Some(_))
          | (Some(false), Some(_)) => enableTtl(tableName)
          | _ => ttl->Js.Promise.resolve
          }
        )
        ->Pulumi.Output.fromPromise
      );

let enablePointInTimeRecovery = tableName => {
  Js.log({j|$__MODULE__: enablePointInTimeRecovery for $tableName|j});
  AwsSdk.DynamoDb_DynamoDb.(
    updateContinuousBackups(
      UpdateContinuousBackupsInput.make(
        ~_TableName=tableName,
        ~_PointInTimeRecoverySpecification=
          UpdateContinuousBackupsInput.PointInTimeRecoverySpecification.make(
            ~_PointInTimeRecoveryEnabled=true,
          ),
      ),
    )
  )
  ->Js.Promise.then_(
      res =>
        TablePointInTimeRecovery.make(
          ~enabled=
            res##_ContinuousBackupsDescription##_ContinuousBackupsStatus
            == "ENABLED",
        )
        ->Js.Promise.resolve,
      _,
    );
};

let verifyPointInTimeRecovery = (table: table) =>
  (table##name, table##pointInTimeRecovery)
  ->Pulumi.Output.all2
  ->Pulumi.Output.flatMap(((tableName, pointInTimeRecovery)) =>
      (
        switch (pointInTimeRecovery##enabled) {
        | false => enablePointInTimeRecovery(tableName)
        | true => pointInTimeRecovery->Js.Promise.resolve
        }
      )
      ->Pulumi.Output.fromPromise
    );

let updateTable: (~ttl: int=?, table) => table =
  (~ttl=?, table) => {
    let newTtl = verifyTtl(~expectedTtl=?ttl, table);
    let newPointInTimeRecovery = verifyPointInTimeRecovery(table);

    table->Js.Obj.assign({
      "ttl": newTtl,
      "pointInTimeRecovery": newPointInTimeRecovery,
    });
  };

let makeTableArgs =
    (
      ~attributes,
      ~globalSecondaryIndexes=?,
      ~ttl: option(int)=?,
      ~rangeKey=?,
      ~restoreSourceName=?,
    ) => {
  let ttl =
    ttl->Belt.Option.map(_ =>
      PulumiAws.DynamoDb.Table.Args.TableTtl.make(
        ~enabled=true,
        ~attributeName=Util_DynamoDb_Runtime.purgeTimeAttributeName,
      )
      ->Pulumi.Input.wrap
    );
  let restoreDateTime = Reventless.Env.restoreDateTime;

  PulumiAws.DynamoDb.Table.Args.make(
    ~attributes=attributes->Pulumi.Input.wrap,
    ~hashKey="id"->Pulumi.Input.wrap,
    ~rangeKey=?rangeKey->Belt.Option.map(Pulumi.Input.wrap),
    ~billingMode=`PAY_PER_REQUEST,
    ~globalSecondaryIndexes?,
    ~ttl?,
    ~pointInTimeRecovery=
      PulumiAws.DynamoDb.Table.Args.PointInTimeRecovery.make(~enabled=true)
      ->Pulumi.Input.wrap,
    ~restoreSourceName=?restoreSourceName->Belt.Option.map(Pulumi.Input.wrap),
    ~restoreDateTime=?
      restoreSourceName->Belt.Option.flatMap(_ =>
        restoreDateTime->Belt.Option.map(Pulumi.Input.wrap)
      ),
    ~restoreToLatestTime=?
      restoreSourceName->Belt.Option.map(_ =>
        restoreDateTime->Belt.Option.isNone->Pulumi.Input.wrap
      ),
  );
};

let option2Str = opt =>
  switch (opt) {
  | Some(value) => {j|Some($value)|j}
  | None => "None"
  };

let makeTable =
    (
      ~attributes,
      ~globalSecondaryIndexes=?,
      ~ttl: option(int)=?,
      ~rangeKey=?,
      ~opts,
      name,
    ) => {
  let restoreSourceName =
    Pulumi.Config.make(Some("restore"))
    ->Pulumi.Config.getObject("tables")
    ->Belt.Option.flatMap(tables => tables->Js.Dict.get(name));

  let (dependencies, registerResource) =
    Util_DynamoDb_TableManager.getDependencies();

  let table =
    PulumiAws.DynamoDb.Table.make(
      ~name,
      ~args=
        makeTableArgs(
          ~attributes,
          ~globalSecondaryIndexes?,
          ~ttl?,
          ~rangeKey?,
          ~restoreSourceName?,
          (),
        ),
      ~opts=
        opts->Js.Obj.assign({
          "dependsOn": dependencies->Pulumi.Output.asInput,
        }),
      (),
    );

  registerResource(. table->Pulumi.Resource.makeFromJs);

  restoreSourceName->Belt.Option.isSome
    // Workaround when restore enabled
    ? updateTable(~ttl?, table) : table;
};

let findResource = resources =>
  resources->Reventless.Util.Adapter.findResource(
    Util_DynamoDb_Runtime.service,
  );

let findUnwrappedResource = resources =>
  resources->Reventless.Util.Adapter.findUnwrappedResource(
    Util_DynamoDb_Runtime.service,
  );

let findResourceInOutput = resourcesOutput =>
  resourcesOutput->Reventless.Util.Adapter.findResourceInOutput(
    Util_DynamoDb_Runtime.service,
  );
