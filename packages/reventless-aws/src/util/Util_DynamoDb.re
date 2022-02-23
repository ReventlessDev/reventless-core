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
