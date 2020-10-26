open AwsSdk.DynamoDb.DocumentClient;

let put = (table: PulumiAws.DynamoDb.Table.t, item) =>
  putWithTableName(table##name->Pulumi.Output.get, item);

let delete = (table: PulumiAws.DynamoDb.Table.t, id) =>
  deleteWithTableName(table##name->Pulumi.Output.get, id, None);

let queryById = (table: PulumiAws.DynamoDb.Table.t, id) =>
  queryByIdWithTableName(table##name->Pulumi.Output.get, id);

let keysFromResource = (resource: Reventless.Adapter.resource) =>
  switch (resource##info |> Pulumi.Output.get |> Js.String.split(",")) {
  | [||] =>
    Js.Exn.raiseError(
      "No id field given for table " ++ resource##name->Pulumi.Output.get,
    )
  | [|id|]
  | [|id, ""|] => (id, None)
  | parts => (parts[0], Some(parts[1]))
  };

let toJson =
  fun
  | Reventless.QueryDb.String(str) => Js.Json.string(str)
  | Int(int) => Js.Json.number(float_of_int(int))
  | Bool(bool) => Js.Json.boolean(bool);

[@bs.val] [@bs.scope "JSON"] external parseJs: string => Js.t(_) = "parse";

let createFilters = filters =>
  filters->Belt.List.mapWithIndex((idx, (key, comparator, value)) => {
    let valueName = {j|$key$idx|j};
    (
      switch (comparator) {
      | Reventless.QueryDb.Equal => {j|#$key = :$valueName|j}
      | Unequal => {j|#$key <> :$valueName|j}
      | LessOrEqual => {j|#$key <= :$valueName|j}
      | Less => {j|#$key < :$valueName|j}
      | GreaterOrEqual => {j|#$key >= :$valueName|j}
      | Greater => {j|#$key > :$valueName|j}
      | Exists => {j|attribute_exists( #$key )|j}
      | NotExists => {j|attribute_not_exists( #$key )|j}
      | Contains => {j|contains( #$key, :$valueName )|j}
      | NotContains => {j|NOT contains( #$key, :$valueName )|j}
      | BeginsWith => {j|begins_with( #$key, :$valueName )|j}
      },
      (({j|#$key|j}, key), ({j|:$valueName|j}, value |> toJson)),
    );
  })
  |> Belt.List.unzip;

let queryByTableName =
    (~tableName, ~key, ~value, ~filterConfigs, ~ascending, ~limit) => {
  let (filterExpressions, filterNamesValues) = filterConfigs |> createFilters;
  let filterExpression =
    switch (filterExpressions) {
    | [] => None
    | filterExpressions => Some(filterExpressions |> String.concat(" AND "))
    };

  let (filterNames, filterValues) = filterNamesValues |> Belt.List.unzip;
  let attributeValues =
    [(":value", value |> toJson)]
    @ filterValues
    |> Js.Dict.fromList
    |> Js.Json.object_
    |> Js.Json.stringify
    |> parseJs;

  let attributeNames = [("#key", key)] @ filterNames |> Js.Dict.fromList;

  let params =
    AwsSdk.DynamoDb.DocumentClient.QueryInput.make(
      ~_TableName=tableName,
      ~_IndexName=?
        if (key == "id") {
          None;
        } else {
          Some(key);
        },
      ~_KeyConditionExpression="#key = :value",
      ~_FilterExpression=?filterExpression,
      ~_ExpressionAttributeNames=attributeNames,
      ~_ExpressionAttributeValues=attributeValues,
      ~_ScanIndexForward=ascending,
      ~_Limit=limit,
      (),
    );
  AwsSdk.DynamoDb.DocumentClient.queryRecursive(~params)
  |> Js.Promise.then_(result =>
       Js.Promise.resolve(
         result##_Items
         ->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn),
       )
     )
  |> Js.Promise.catch(err => {
       Js.log2("Task.query error:", err);
       Js.Promise.resolve([||]);
     });
};

let queryByServiceNameMaker = queryQueryDb =>
  (. serviceName, key, value, filterConfigs, ascending, limit) =>
    queryByTableName(
      ~tableName=
        queryQueryDb(serviceName)##name->Reventless.OutputFailsafeRuntime.get,
      ~key,
      ~value,
      ~filterConfigs,
      ~ascending,
      ~limit,
    );
