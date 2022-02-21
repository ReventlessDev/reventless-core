let service = "DynamoDbStream";

let toInfo = (table: PulumiAws.DynamoDb.Table.t) => {
  // NOTE: workaround if stream is not enabled after creation of table (e.g. after restore)
  let streamArn =
    (table##name, table##streamArn)
    ->Pulumi.Output.all2
    ->Pulumi.Output.flatMap(
        fun
        | (_, Some(streamArn)) when streamArn->Js.String2.trim != "" =>
          streamArn->Pulumi.Output.make
        | (tableName, _) =>
          AwsSdk.DynamoDb.DynamoDb.(
            updateTable(
              UpdateTableInput.make(
                ~_TableName=tableName,
                ~_StreamSpecification=
                  UpdateTableInput.StreamSpecification.make(
                    ~_StreamEnabled=true,
                    (),
                  ),
                (),
              ),
            )
            ->Js.Promise.then_(
                table => {
                  let streamArn = table##_TableDescription##_LatestStreamArn;
                  Js.log(
                    {j|$__MODULE__: enabled DynamoDbStream for table $tableName: $streamArn|j},
                  );
                  streamArn->Js.Promise.resolve;
                },
                _,
              )
          )
          ->Pulumi.Output.fromPromise,
      );

  (table##hashKey, table##rangeKey, streamArn)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((hashKey, rangeKey, streamArn)) =>
      hashKey
      ++ ","
      ++ rangeKey->Belt.Option.getWithDefault("")
      ++ ","
      ++ streamArn
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
