let service = "DynamoDb";

let toInfo = (table: PulumiAws.DynamoDb.Table.t) =>
  (table##hashKey, table##rangeKey)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((hashKey, rangeKey)) =>
      hashKey ++ "," ++ rangeKey->Belt.Option.getWithDefault("")
    );

let toResource = (table: PulumiAws.DynamoDb.Table.t) =>
  Reventless.Adapter.resource(
    ~service,
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
let updateTable = (table, ttl) => {
  let _ =
    table##name
    ->Pulumi.Output.flatMap(tableName =>
        AwsSdk.DynamoDb_DynamoDb.(
          ttl
          ->Belt.Option.map(_ =>
              updateTimeToLive(
                UpdateTimeToLiveInput.make(
                  ~_TableName=tableName,
                  ~_TimeToLiveSpecification=
                    UpdateTimeToLiveInput.TimeToLiveSpecification.make(
                      ~_Enabled=true,
                      ~_AttributeName=QueryDbStorage_DynamoDb_Runtime.purgeTimeAttributeName,
                    ),
                ),
              )
            )
          ->Belt.Option.getWithDefault({}->Js.Promise.resolve),
          updateContinuousBackups(
            UpdateContinuousBackupsInput.make(
              ~_TableName=tableName,
              ~_PointInTimeRecoverySpecification=
                UpdateContinuousBackupsInput.PointInTimeRecoverySpecification.make(
                  ~_PointInTimeRecoveryEnabled=true,
                ),
            ),
          ),
        )
        ->Js.Promise.all2
        ->Pulumi.Output.fromPromise
      );
  table;
};

let makeTableArgs =
    (
      ~attributes,
      ~globalSecondaryIndexes=?,
      ~ttl=?,
      ~rangeKey=?,
      ~restoreSourceName=?,
    ) =>
  PulumiAws.DynamoDb.Table.Args.(
    make(
      ~attributes=attributes->Pulumi.Input.wrap,
      ~hashKey="id"->Pulumi.Input.wrap,
      ~rangeKey=?rangeKey->Belt.Option.map(Pulumi.Input.wrap),
      ~billingMode=`PAY_PER_REQUEST,
      ~globalSecondaryIndexes?,
      ~ttl=?
        ttl->Belt.Option.map(_ =>
          TableTtl.make(
            ~attributeName=
              QueryDbStorage_DynamoDb_Runtime.purgeTimeAttributeName->Pulumi.Input.wrap,
            ~enabled=true->Pulumi.Input.wrap,
            (),
          )
          ->Pulumi.Input.wrap
        ),
      ~pointInTimeRecovery=
        PointInTimeRecovery.make(~enabled=true)->Pulumi.Input.wrap,
      ~restoreSourceName=?
        restoreSourceName->Belt.Option.map(Pulumi.Input.wrap),
      ~restoreDateTime=?
        restoreSourceName->Belt.Option.flatMap(_ =>
          Reventless.Env.restoreDateTime->Belt.Option.map(Pulumi.Input.wrap)
        ),
      ~restoreToLatestTime=?
        restoreSourceName->Belt.Option.map(_ =>
          Reventless.Env.restoreDateTime->Belt.Option.isNone->Pulumi.Input.wrap
        ),
    )
  );

let makeTable =
    (~attributes, ~globalSecondaryIndexes=?, ~ttl=?, ~rangeKey=?, ~opts, name) => {
  let restoreSourceName =
    Pulumi.Config.make(Some("restore"))
    ->Pulumi.Config.getObject("tables")
    ->Belt.Option.flatMap(tables => tables->Js.Dict.get(name));

  let (dependencies, registerResource) =
    Util_DynamoDb_TableManager.getDependencies();

  let table =
    PulumiAws.DynamoDb.Table.(
      make(
        ~name,
        ~args=
          makeTableArgs(
            ~attributes,
            ~globalSecondaryIndexes?,
            ~ttl,
            ~rangeKey?,
            ~restoreSourceName?,
            (),
          ),
        ~opts=
          opts->Js.Obj.assign({
            "dependsOn": dependencies->Pulumi.Output.asInput,
          }),
        (),
      )
    );
  ();

  registerResource(. table->Pulumi.Resource.makeFromJs);

  restoreSourceName->Belt.Option.isSome
    // Workaround when restore enabled
    ? table->updateTable(ttl) : table;
};
