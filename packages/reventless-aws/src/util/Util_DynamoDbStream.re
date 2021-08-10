let service = "DynamoDbStream";

let toInfo = (table: PulumiAws.DynamoDb.Table.t) =>
  (table##hashKey, table##rangeKey, table##streamArn)
  ->Pulumi.Output.all3
  ->Pulumi.Output.apply(((hashKey, rangeKey, streamArn)) =>
      hashKey
      ++ ","
      ++ rangeKey->Belt.Option.getWithDefault("")
      ++ ","
      ++ streamArn->Belt.Option.getWithDefault("")
    );

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
