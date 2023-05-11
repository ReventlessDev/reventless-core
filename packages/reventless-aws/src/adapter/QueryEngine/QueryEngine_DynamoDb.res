let toJson = x =>
  switch x {
  | ReventlessSpec.QueryEngine.String(str) => Js.Json.string(str)
  | Int(int) => Js.Json.number(float_of_int(int))
  | Bool(bool) => Js.Json.boolean(bool)
  }

@val @scope("JSON") external parseJs: string => _ = "parse"

let createFilters = filters =>
  filters
  ->Belt.Array.mapWithIndex((idx, (key, comparator, value)) => {
    let valueName = `${key}${idx->Belt.Int.toString}`
    (
      switch comparator {
      | ReventlessSpec.QueryEngine.Equal => `#${key} = :${valueName}`
      | Unequal => `#${key} <> :${valueName}`
      | LessOrEqual => `#${key} <= :${valueName}`
      | Less => `#${key} < :${valueName}`
      | GreaterOrEqual => `#${key} >= :${valueName}`
      | Greater => `#${key} > :${valueName}`
      | Exists => `attribute_exists( #${key} )`
      | NotExists => `attribute_not_exists( #${key} )`
      | Contains => `contains( #${key}, :${valueName} )`
      | NotContains => `NOT contains( #${key}, :${valueName} )`
      | BeginsWith => `begins_with( #${key}, :${valueName} )`
      },
      ((`#${key}`, key), (`:${valueName}`, value->toJson)),
    )
  })
  ->Belt.Array.unzip

let queryByTableName = async (
  ~tableName,
  ~key="id",
  ~id,
  ~filterConfigs=[],
  ~ascending=true,
  ~limit=1,
  (),
) => {
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilters
  let filterExpression = switch filterExpressions {
  | [] => None
  | filterExpressions => Some(filterExpressions->Js.Array2.joinWith(" AND "))
  }

  let (filterNames, filterValues) = filterNamesValues->Belt.Array.unzip
  let attributeValues =
    Belt.Array.concatMany([[(":value", id->toJson)], filterValues])
    ->Js.Dict.fromArray
    ->Js.Json.object_
    ->Js.Json.stringify
    ->parseJs

  let attributeNames = Belt.Array.concatMany([[("#key", key)], filterNames])->Js.Dict.fromArray

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
  switch await AwsSdk.DynamoDb.DocumentClient.queryRecursive(~params, ()) {
  | result => result["_Items"]->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn)
  | exception err =>
    Js.log2("Task.query error:", err)
    []
  }
}

let scanByTableName = async (~tableName, ~filterConfigs, ~limit) => {
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilters
  let filterExpression = switch filterExpressions {
  | [] => None
  | filterExpressions => Some(filterExpressions->Js.Array2.joinWith(" AND "))
  }

  let (filterNames, filterValues) = filterNamesValues->Belt.Array.unzip
  let attributeValues = filterValues->Js.Dict.fromArray->Js.Json.object_->Js.Json.stringify->parseJs

  let attributeNames = filterNames->Js.Dict.fromArray

  let params = AwsSdk.DynamoDb.DocumentClient.ScanInput.make(
    ~_TableName=tableName,
    ~_FilterExpression=?filterExpression,
    ~_ExpressionAttributeNames=attributeNames,
    ~_ExpressionAttributeValues=attributeValues,
    ~_Limit=limit,
    (),
  )
  switch await AwsSdk.DynamoDb.DocumentClient.scanRecursive(~params, ()) {
  | result => result["_Items"]->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn)
  | exception Js.Exn.Error(e) =>
    Js.log2("Task.query error:", e)
    []
  }
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
