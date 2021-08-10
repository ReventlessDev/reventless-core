let service = "DynamoDbStream";

let streamArnFromDynamoDbTableResource = table =>
  table##info
  ->Pulumi.Output.apply(resourceInfo =>
      switch (resourceInfo |> Js.String.split(",")) {
      | parts
          when parts->Belt.Array.length < 3 || parts[2]->Js.String2.trim == "" =>
        Js.Exn.raiseError(
          "No streamArn field given for table "
          ++ table##name->Pulumi.Output.get,
        )
      | parts => parts[2]
      }
    );

let toResource = (table: ReventlessSpec.Adapter.resource) => {
  let streamArn = table->streamArnFromDynamoDbTableResource;

  Reventless.Adapter.resource(
    ~service,
    ~name=table##name,
    ~id=streamArn,
    ~urn=streamArn,
    ~info=table##name->Pulumi.Output.apply(_ => ""),
  );
};
