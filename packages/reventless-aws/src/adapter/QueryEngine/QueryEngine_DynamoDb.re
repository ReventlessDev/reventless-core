open Reventless;

let toJson =
  fun
  | ReventlessSpec.QueryEngine.String(str) => Js.Json.string(str)
  | Int(int) => Js.Json.number(float_of_int(int))
  | Bool(bool) => Js.Json.boolean(bool);

[@bs.val] [@bs.scope "JSON"] external parseJs: string => Js.t(_) = "parse";

let createFilters = filters =>
  filters->Belt.List.mapWithIndex((idx, (key, comparator, value)) => {
    let valueName = {j|$key$idx|j};
    (
      switch (comparator) {
      | ReventlessSpec.QueryEngine.Equal => {j|#$key = :$valueName|j}
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
    (
      ~tableName,
      ~key="id",
      ~id,
      ~filterConfigs=[],
      ~ascending=true,
      ~limit=1,
      (),
    ) => {
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilters;
  let filterExpression =
    switch (filterExpressions) {
    | [] => None
    | filterExpressions => Some(filterExpressions->String.concat(" AND ", _))
    };

  let (filterNames, filterValues) = filterNamesValues->Belt.List.unzip;
  let attributeValues =
    ([(":value", id->toJson)] @ filterValues)
    ->Js.Dict.fromList
    ->Js.Json.object_
    ->Js.Json.stringify
    ->parseJs;

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
  AwsSdk.DynamoDb.DocumentClient.queryRecursive(~params, ())
  ->Js.Promise.then_(
      result =>
        Js.Promise.resolve(
          result##_Items
          ->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn),
        ),
      _,
    )
  ->Js.Promise.catch(
      err => {
        Js.log2("Task.query error:", err);
        Js.Promise.resolve([||]);
      },
      _,
    );
};

let scanByTableName = (~tableName, ~filterConfigs, ~limit) => {
  let (filterExpressions, filterNamesValues) = filterConfigs |> createFilters;
  let filterExpression =
    switch (filterExpressions) {
    | [] => None
    | filterExpressions => Some(filterExpressions |> String.concat(" AND "))
    };

  let (filterNames, filterValues) = filterNamesValues |> Belt.List.unzip;
  let attributeValues =
    filterValues
    |> Js.Dict.fromList
    |> Js.Json.object_
    |> Js.Json.stringify
    |> parseJs;

  let attributeNames = filterNames |> Js.Dict.fromList;

  let params =
    AwsSdk.DynamoDb.DocumentClient.ScanInput.make(
      ~_TableName=tableName,
      ~_FilterExpression=?filterExpression,
      ~_ExpressionAttributeNames=attributeNames,
      ~_ExpressionAttributeValues=attributeValues,
      ~_Limit=limit,
      (),
    );
  AwsSdk.DynamoDb.DocumentClient.scanRecursive(~params, ())
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

let make: QueryDb.Adapter.queryEngineMaker =
  resources => {
    scan: (~viewName) =>
      scanByTableName(
        ~tableName=
          resources
          ->Util_QueryDb.getStorageResource(None, viewName)
          ->Belt.Option.getExn##name
          ->OutputFailsafeRuntime.get,
      ),
    query: (~viewName) =>
      queryByTableName(
        ~tableName=
          resources
          ->Util_QueryDb.getStorageResource(None, viewName)
          ->Belt.Option.getExn##name
          ->OutputFailsafeRuntime.get,
      ),
  };
