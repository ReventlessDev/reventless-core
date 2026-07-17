open Reventless.QueryEngine

let toJson = x =>
  switch x {
  | String(str) => JSON.Encode.string(str)
  | Int(int) => JSON.Encode.float(Int.toFloat(int))
  | Bool(bool) => JSON.Encode.bool(bool)
  }

@val @scope("JSON") external parseJs: string => _ = "parse"

let createSubIdExprNamesValues = (subIdConfig: option<SubId.config>) =>
  subIdConfig->Option.map(((subIdName, comparator, value)) => {
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
  ->Array.mapWithIndex(((fieldName, comparator, value), idx) => {
    let valueName = `${fieldName}${idx->Int.toString}`
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
  ->Array.unzip

let queryByTableName = (
  ~tableName,
  ~key="id",
  ~id,
  ~subIdConfig=?,
  ~filterConfigs=[],
  ~ascending=true,
  ~limit=1,
) => {
  let (subIdExpressions, subIdNamesValues) =
    subIdConfig->createSubIdExprNamesValues->Option.getOr(([], []))
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilterExprNamesValues

  let keyConditionExpression =
    ["#key = :value"]->Array.concat(subIdExpressions)->Array.joinUnsafe(" AND ")
  let filterExpression = switch filterExpressions {
  | [] => None
  | filterExpressions => Some(filterExpressions->Array.joinUnsafe(" AND "))
  }

  let (names, values) = subIdNamesValues->Array.concat(filterNamesValues)->Array.unzip
  let attributeValues =
    Array.flat([[(":value", id->toJson)], values])
    ->Dict.fromArray
    ->JSON.Encode.object
    ->JSON.stringify
    ->parseJs

  let attributeNames = Array.flat([[("#key", key)], names])->Dict.fromArray

  let params: AwsSdk.DynamoDb.DocumentClient.QueryCommand.input = {
    {
      tableName,
      indexName: ?(
        if key == "id" {
          None
        } else {
          Some(key)
        }
      ),
      keyConditionExpression,
      ?filterExpression,
      expressionAttributeNames: attributeNames,
      expressionAttributeValues: attributeValues,
      scanIndexForward: ascending,
      limit,
    }
  }
  ReventlessCore.EffectLogger.logDebug(~comp=__MODULE__, "queryByTableName params: " ++ params->JSON.stringifyAny->Option.getOr(""))
  ->Effect.flatMap(_ =>
    Util_DynamoDb_Runtime.queryStream(params)
    ->Stream.runCollect
    ->Effect.map(items => items->Array.map(js => js->JSON.stringify->JSON.parseOrThrow))
    ->Effect.catchAll(err => {
      let msg = DynamoDb_Error.message(err)
      ReventlessCore.EffectLogger.logError(~comp=__MODULE__, "queryByTableName: " ++ msg)->Effect.map(_ => [])
    })
  )
  ->Effect.runPromise
}

let scanByTableName = (~tableName, ~filterConfigs, ~limit) => {
  let (filterExpressions, filterNamesValues) = filterConfigs->createFilterExprNamesValues
  let (filterNames, filterValues) = filterNamesValues->Array.unzip
  let (filterExpression, attributeNames, attributeValues) = switch filterExpressions {
  | [] => (None, None, None)
  | filterExpressions => (
      Some(filterExpressions->Array.joinUnsafe(" AND ")),
      Some(filterNames->Dict.fromArray),
      Some(filterValues->Dict.fromArray->JSON.Encode.object->JSON.stringify->parseJs),
    )
  }

  let params: AwsSdk.DynamoDb.DocumentClient.ScanCommand.input = {
    tableName,
    ?filterExpression,
    expressionAttributeNames: ?attributeNames,
    expressionAttributeValues: ?attributeValues,
    limit,
  }
  ReventlessCore.EffectLogger.logDebug(~comp=__MODULE__, "scanByTableName params: " ++ params->JSON.stringifyAny->Option.getOr(""))
  ->Effect.flatMap(_ =>
    Util_DynamoDb_Runtime.scanStream(params)
    ->Stream.runCollect
    ->Effect.map(items => items->Array.map(js => js->JSON.stringify->JSON.parseOrThrow))
    ->Effect.catchAll(err => {
      let msg = DynamoDb_Error.message(err)
      ReventlessCore.EffectLogger.logError(~comp=__MODULE__, "scanByTableName: " ++ msg)->Effect.map(_ => [])
    })
  )
  ->Effect.runPromise
}

let make: ReventlessCore.QueryDb_Adapter.queryEngineMaker = allQueryDbs => {
  // B3.1: Postgres-backed read models have NO DynamoDB resource — exclude them
  // instead of failing findResource at deploy time. They are not reachable via
  // this engine (getRuntimeResource raises its explicit not-found error at
  // query time); see docs/plans/aws-postgres-querydb-adapter.md § B3.1b.
  let dynamoDbQueryDbs =
    allQueryDbs
    ->Dict.toArray
    ->Array.filter(((_, queryDb: ReventlessCore.QueryDb.outputs)) =>
      queryDb.resources->Array.length > 0
    )
    ->Dict.fromArray
  let allRuntimeQueryDbsOutputs = Dict.mapValues(dynamoDbQueryDbs, (
    queryDb: ReventlessCore.QueryDb.outputs,
  ) =>
    queryDb.resources
    ->Util.DynamoDb.findResource
    ->ReventlessCore.Adapter.resourceToResolvedOutput
  )->Pulumi.Output.allDict

  let tableName = (allRuntimeQueryDbs, readModelName) =>
    (allRuntimeQueryDbs->ReventlessCore.Util_QueryDbRuntime.getRuntimeResource(readModelName)).name

  allRuntimeQueryDbsOutputs->Pulumi.Output.apply(allRuntimeQueryDbs => {
    scan: (~readModelName, ~filterConfigs, ~limit) =>
      scanByTableName(
        ~tableName=allRuntimeQueryDbs->tableName(readModelName),
        ~filterConfigs,
        ~limit,
      ),
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
        ~tableName=allRuntimeQueryDbs->tableName(readModelName),
        ~key?,
        ~id,
        ~subIdConfig?,
        ~filterConfigs?,
        ~ascending?,
        ~limit?,
      ),
  })
}
