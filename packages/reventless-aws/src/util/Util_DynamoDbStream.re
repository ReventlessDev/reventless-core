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
  let streamArn =
    (table##name, table##streamArn)
    ->Pulumi.Output.all2
    ->Pulumi.Output.flatMap(((tableName, streamArn)) =>
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
            ->Js.Promise.all3
            ->Js.Promise.then_(
                ((table, _, _)) =>
                  table##_TableDescription##_LatestStreamArn
                  ->Js.Promise.resolve,
                _,
              )
            ->Pulumi.Output.fromPromise
          : Pulumi.Output.make("")
      );
  table->Js.Obj.assign({"streamArn": Some(streamArn)});
};
