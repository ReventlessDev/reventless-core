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

let toResource = (table: PulumiAws.DynamoDb.Table.t) =>
  Reventless.Adapter.resource(
    ~service="DynamoDb",
    ~name=table##name,
    ~id=table##id,
    ~urn=table##arn,
    ~info=table->toInfo,
  );
