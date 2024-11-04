open ReventlessSpec.QueryEngine

let toJson = x =>
  switch x {
  | String(str) => Js.Json.string(str)
  | Int(int) => Js.Json.number(float_of_int(int))
  | Bool(bool) => Js.Json.boolean(bool)
  }

@val @scope("JSON") external parseJs: string => _ = "parse"

let createSubIdExprNamesValues = (subIdConfig: option<SubId.config>) =>
  subIdConfig->Belt.Option.map(((subIdName, comparator, value)) => {
    (
      [
        switch comparator {
        | SubId.Equal => `#${subIdName} = :${subIdName}`
        | Unequal => `#${subIdName} <> :${subIdName}`
        | LessOrEqual => `#${subIdName} <= :${subIdName}`
        | Less => `#${subIdName} < :${subIdName}`
        | GreaterOrEqual => `#${subIdName} >= :${subIdName}`
        | Greater => `#${subIdName} > :${subIdName}`
        | BeginsWith => `begins_with( #${subIdName}, :${subIdName} )`
        },
      ],
      [((`#${subIdName}`, subIdName), (`:${subIdName}`, value->toJson))],
    )
  })

let createFilterExprNamesValues = filterConfigs =>
  filterConfigs
  ->Belt.Array.mapWithIndex((idx, (fieldName, comparator, value)) => {
    let valueName = `${fieldName}${idx->Belt.Int.toString}`
    (
      switch comparator {
      | Filter.Equal => `#${fieldName} = :${valueName}`
      | Unequal => `#${fieldName} <> :${valueName}`
      | LessOrEqual => `#${fieldName} <= :${valueName}`
      | Less => `#${fieldName} < :${valueName}`
      | GreaterOrEqual => `#${fieldName} >= :${valueName}`
      | Greater => `#${fieldName} > :${valueName}`
      | Exists => `attribute_exists( #${fieldName} )`
      | NotExists => `attribute_not_exists( #${fieldName} )`
      | Contains => `contains( #${fieldName}, :${valueName} )`
      | NotContains => `NOT contains( #${fieldName}, :${valueName} )`
      | BeginsWith => `begins_with( #${fieldName}, :${valueName} )`
      },
      ((`#${fieldName}`, fieldName), (`:${valueName}`, value->toJson)),
    )
  })
  ->Belt.Array.unzip

let queryByTableName = async (
  ~tableName,
  ~key="id",
  ~id,
  ~subIdConfig=?,
  ~filterConfigs=[],
  ~ascending=true,
  ~limit=1,
) => {
  let (subIdExpressions, subIdNamesValues) =
    subIdConfig->createSubIdExprNamesValues->Belt.Option.getWithDefault(([], []))
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilterExprNamesValues

  let keyConditionExpression =
    ["#key = :value"]
    ->Belt.Array.concat(subIdExpressions)
    ->Js.Array2.joinWith(" AND ")
  let filterExpression = switch filterExpressions {
  | [] => None
  | filterExpressions => Some(filterExpressions->Js.Array2.joinWith(" AND "))
  }

  let (names, values) = subIdNamesValues->Belt.Array.concat(filterNamesValues)->Belt.Array.unzip
  let attributeValues =
    Belt.Array.concatMany([[(":value", id->toJson)], values])
    ->Js.Dict.fromArray
    ->Js.Json.object_
    ->Js.Json.stringify
    ->parseJs

  let attributeNames = Belt.Array.concatMany([[("#key", key)], names])->Js.Dict.fromArray

  let params = AwsSdk.DynamoDb.DocumentClient.QueryInput.make(
    ~_TableName=tableName,
    ~_IndexName=?if key == "id" {
      None
    } else {
      Some(key)
    },
    ~_KeyConditionExpression=keyConditionExpression,
    ~_FilterExpression=?filterExpression,
    ~_ExpressionAttributeNames=attributeNames,
    ~_ExpressionAttributeValues=attributeValues,
    ~_ScanIndexForward=ascending,
    ~_Limit=limit,
    (),
  )
  Js.log2("QueryEngine_DynamoDb.queryByTableName params:", params)
  switch await AwsSdk.DynamoDb.DocumentClient.queryRecursive(~params)() {
  | result => result["_Items"]->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn)
  | exception err =>
    Js.log2("Task.query error:", err)
    []
  }
}

let scanByTableName = async (~tableName, ~filterConfigs, ~limit) => {
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilterExprNamesValues
  let (filterNames, filterValues) = filterNamesValues->Belt.Array.unzip
  let (filterExpression, attributeNames, attributeValues) = switch filterExpressions {
  | [] => (None, None, None)
  | filterExpressions => (
      Some(filterExpressions->Js.Array2.joinWith(" AND ")),
      Some(filterNames->Js.Dict.fromArray),
      Some(filterValues->Js.Dict.fromArray->Js.Json.object_->Js.Json.stringify->parseJs),
    )
  }

  let params = AwsSdk.DynamoDb.DocumentClient.ScanInput.make(
    ~_TableName=tableName,
    ~_FilterExpression=?filterExpression,
    ~_ExpressionAttributeNames=?attributeNames,
    ~_ExpressionAttributeValues=?attributeValues,
    ~_Limit=limit,
    (),
  )
  Js.log2("QueryEngine_DynamoDb.scanByTableName params:", params)
  switch await AwsSdk.DynamoDb.DocumentClient.scanRecursive(~params)() {
  | result => result["_Items"]->Belt.Array.map(js => js->Js.Json.stringify->Js.Json.parseExn)
  | exception Js.Exn.Error(e) =>
    Js.log2("Task.scan error:", e)
    []
  }
}

let make: Reventless.QueryDb.Adapter.queryEngineMaker = allQueryDbs => {
  let tableName = readModelName =>
    (
      allQueryDbs
      ->Reventless.Util_QueryDbRuntime.getLocalStorageResources(readModelName)
      ->Util_DynamoDb_Runtime.findResource
    ).name->Reventless.OutputFailsafeRuntime.get

  {
    scan: (~readModelName, ~filterConfigs, ~limit) =>
      scanByTableName(~tableName=tableName(readModelName), ~filterConfigs, ~limit),
    query: (
      ~readModelName,
      ~key=?,
      ~id,
      ~subIdConfig=?,
      ~filterConfigs=?,
      ~ascending=?,
      ~limit=?,
    ) =>
      queryByTableName(
        ~tableName=tableName(readModelName),
        ~key?,
        ~id,
        ~subIdConfig?,
        ~filterConfigs?,
        ~ascending?,
        ~limit?,
      ),
  }
}
