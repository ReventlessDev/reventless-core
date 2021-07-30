open AwsSdk.DynamoDb.DocumentClient;

let put = (table: PulumiAws.DynamoDb.Table.t, item) =>
  putWithTableName(table##name->Pulumi.Output.get, item);

let delete = (table: PulumiAws.DynamoDb.Table.t, id) =>
  deleteWithTableName(table##name->Pulumi.Output.get, id, None);

let queryById = (table: PulumiAws.DynamoDb.Table.t, id) =>
  queryByIdWithTableName(table##name->Pulumi.Output.get, id);

let keysFromResource = (resource: ReventlessSpec.Adapter.resource) =>
  switch (resource##info |> Pulumi.Output.get |> Js.String.split(",")) {
  | [||] =>
    Js.Exn.raiseError(
      "No id field given for table " ++ resource##name->Pulumi.Output.get,
    )
  | [|id|]
  | [|id, ""|] => (id, None)
  | parts => (parts[0], Some(parts[1]))
  };

let streamArnFromResource = (resource: ReventlessSpec.Adapter.resource) =>
  switch (resource##info |> Pulumi.Output.get |> Js.String.split(",")) {
  | parts when parts->Belt.Array.length < 3 || parts[2]->Js.String2.trim == "" =>
    Js.Exn.raiseError(
      "No streamArn field given for table "
      ++ resource##name->Pulumi.Output.get,
    )
  | parts => parts[2]
  };
