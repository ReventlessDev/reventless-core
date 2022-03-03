let service = "DynamoDbStream";

let toInfo = (table: PulumiAws.DynamoDb.Table.t) => {
  (table##hashKey, table##rangeKey, table##streamArn)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((hashKey, rangeKey, streamArn)) =>
      hashKey
      ++ ","
      ++ rangeKey->Belt.Option.getWithDefault("")
      ++ ","
      ++ streamArn->Belt.Option.getExn
    );
};

let streamArnFromDynamoDbTableResource = table =>
  (table##info, table##name)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((tableInfo, tableName)) =>
      switch (tableInfo |> Js.String.split(",")) {
      | parts
          when parts->Belt.Array.length < 3 || parts[2]->Js.String2.trim == "" =>
        Js.Exn.raiseError("No streamArn field given for table " ++ tableName)
      | parts => parts[2]
      }
    );

let toResource = (table: PulumiAws.DynamoDb.Table.t) =>
  Reventless.Adapter.resource(
    ~service,
    ~name=table##name,
    ~id=table##id,
    ~urn=table##arn,
    ~info=table->toInfo,
  );

let toStreamResource = (table: ReventlessSpec.Adapter.resource) => {
  let streamArn = table->streamArnFromDynamoDbTableResource;

  Reventless.Adapter.resource(
    ~service,
    ~name=table##name,
    ~id=streamArn,
    ~urn=streamArn,
    ~info=table##name->Pulumi.Output.apply(_ => ""),
  );
};

// Workaround when restore enabled: turn on stream, ttl & pointInTimeRecovery again
let updateTable = (table, ttl) => {
  Js.log2("Start updateTable. ttl:", ttl);
  let streamArn =
    (table##name, table##streamArn)
    ->Pulumi.Output.all2
    ->Pulumi.Output.flatMap(((tableName, streamArn)) => {
        Js.log3(
          "streamArn before:",
          streamArn,
          streamArn->Belt.Option.isSome,
        );
        streamArn->Belt.Option.isNone
          ? AwsSdk.DynamoDb_DynamoDb.(
              updateTable(
                UpdateTableInput.make(
                  ~_TableName=tableName,
                  ~_StreamSpecification=
                    UpdateTableInput.StreamSpecification.make(
                      ~_StreamEnabled=true,
                      ~_StreamViewType=`NEW_IMAGE,
                      (),
                    ),
                  (),
                ),
              ),
              ttl
              ->Belt.Option.map(_ => {
                  Js.log2("Start updateTimeToLive. ttl:", ttl);
                  updateTimeToLive(
                    UpdateTimeToLiveInput.make(
                      ~_TableName=tableName,
                      ~_TimeToLiveSpecification=
                        UpdateTimeToLiveInput.TimeToLiveSpecification.make(
                          ~_Enabled=true,
                          ~_AttributeName=QueryDbStorage_DynamoDb_Runtime.purgeTimeAttributeName,
                        ),
                    ),
                  );
                })
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
            ->Js.Promise.all3
            ->Js.Promise.then_(
                ((table, _, _)) => {
                  let streamArn = table##_TableDescription##_LatestStreamArn;
                  Js.log2("newly set streamArn:", streamArn);
                  Some(streamArn)->Js.Promise.resolve;
                },
                _,
              )
            ->Pulumi.Output.fromPromise
          : Pulumi.Output.make(streamArn);
      });

  streamArn
  ->Pulumi.Output.apply(streamArn =>
      Js.log3("streamArn after:", streamArn, streamArn->Belt.Option.isSome)
    )
  ->ignore;
  let newTable = table->Js.Obj.assign({"streamArn": streamArn});
  (newTable##name, newTable##streamArn)
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((tableName, streamArn)) =>
      Js.log3("newTable: ", tableName, streamArn)
    )
  ->ignore;
  newTable;
};

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
          Util_DynamoDb.makeTableArgs(
            ~attributes,
            ~globalSecondaryIndexes?,
            ~ttl,
            ~rangeKey?,
            ~restoreSourceName?,
            ~streamEnabled=true,
            ~streamViewType=`NEW_IMAGE,
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
