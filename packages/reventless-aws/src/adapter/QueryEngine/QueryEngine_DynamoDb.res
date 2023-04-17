let toJson = x =>
  switch x {
  | ReventlessSpec.QueryEngine.String(str) => Js.Json.string(str)
  | Int(int) => Js.Json.number(float_of_int(int))
  | Bool(bool) => Js.Json.boolean(bool)
  }

@val @scope("JSON") external parseJs: string => _ = "parse"

let createFilters = filters =>
  filters->Belt.List.mapWithIndex((idx, (key, comparator, value)) => {
    let valueName = j`$key$idx`
    (
      switch comparator {
      | ReventlessSpec.QueryEngine.Equal => j`#$key = :$valueName`
      | Unequal => j`#$key <> :$valueName`
      | LessOrEqual => j`#$key <= :$valueName`
      | Less => j`#$key < :$valueName`
      | GreaterOrEqual => j`#$key >= :$valueName`
      | Greater => j`#$key > :$valueName`
      | Exists => j`attribute_exists( #$key )`
      | NotExists => j`attribute_not_exists( #$key )`
      | Contains => j`contains( #$key, :$valueName )`
      | NotContains => j`NOT contains( #$key, :$valueName )`
      | BeginsWith => j`begins_with( #$key, :$valueName )`
      },
      ((j`#$key`, key), (j`:$valueName`, value |> toJson)),
    )
  }) |> Belt.List.unzip

let queryByTableName = (
  ~tableName,
  ~key="id",
  ~id,
  ~filterConfigs=list{},
  ~ascending=true,
  ~limit=1,
  (),
) => {
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilters
  let filterExpression = switch filterExpressions {
  | list{} => None
  | filterExpressions => Some(filterExpressions->String.concat(" AND ", _))
  }

  let (filterNames, filterValues) = filterNamesValues->Belt.List.unzip
  let attributeValues =
    \"@"(list{(":value", id->toJson)}, filterValues)
    ->Js.Dict.fromList
    ->Js.Json.object_
    ->Js.Json.stringify
    ->parseJs

  let attributeNames = \"@"(list{("#key", key)}, filterNames) |> Js.Dict.fromList

  let params = AwsSdk.DynamoDb.DocumentClient.QueryInput.make(
    ~_TableName=tableName,
    ~_IndexName=?if key == "id" {
      None
    } else {
      Some(key)
    },
    ~_KeyConditionExpression="#key = :value",
    ~_FilterExpression=?filterExpression,
    ~_ExpressionAttributeNames=attributeNames,
    ~_ExpressionAttributeValues=attributeValues,
    ~_ScanIndexForward=ascending,
    ~_Limit=limit,
    (),
  )
  AwsSdk.DynamoDb.DocumentClient.queryRecursive(~params, ())
  ->Js.Promise.then_(
    result =>
      Js.Promise.resolve(
        result["_Items"]->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn),
      ),
    _,
  )
  ->Js.Promise.catch(err => {
    Js.log2("Task.query error:", err)
    Js.Promise.resolve([])
  }, _)
}

let scanByTableName = (~tableName, ~filterConfigs, ~limit) => {
  let (filterExpressions, filterNamesValues) = filterConfigs |> createFilters
  let filterExpression = switch filterExpressions {
  | list{} => None
  | filterExpressions => Some(filterExpressions |> String.concat(" AND "))
  }

  let (filterNames, filterValues) = filterNamesValues |> Belt.List.unzip
  let attributeValues =
    filterValues |> Js.Dict.fromList |> Js.Json.object_ |> Js.Json.stringify |> parseJs

  let attributeNames = filterNames |> Js.Dict.fromList

  let params = AwsSdk.DynamoDb.DocumentClient.ScanInput.make(
    ~_TableName=tableName,
    ~_FilterExpression=?filterExpression,
    ~_ExpressionAttributeNames=attributeNames,
    ~_ExpressionAttributeValues=attributeValues,
    ~_Limit=limit,
    (),
  )
  AwsSdk.DynamoDb.DocumentClient.scanRecursive(~params, ())
  |> Js.Promise.then_(result =>
    Js.Promise.resolve(
      result["_Items"]->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn),
    )
  )
  |> Js.Promise.catch(err => {
    Js.log2("Task.query error:", err)
    Js.Promise.resolve([])
  })
}

let make: Reventless.QueryDb.Adapter.queryEngineMaker = allQueryDbs => {
  let tableName = viewName =>
    (
      allQueryDbs
      ->Reventless.Util_QueryDbRuntime.getLocalStorageResources(viewName)
      ->Util_DynamoDb_Runtime.findResource
    )["name"]->Reventless.OutputFailsafeRuntime.get
  {
    scan: (~viewName) => scanByTableName(~tableName=tableName(viewName)),
    query: (~viewName) => queryByTableName(~tableName=tableName(viewName)),
  }
}
