open AwsSdk.DynamoDb.DocumentClient
open Util_DynamoDb_Runtime
// Belt.Result removed — Ok/Error are global in RescriptCore

// True lazy pagination: each DynamoDB page is fetched on demand.
// Per-page retry is handled inside the paginateEffect callback.
// Stream.take(n) short-circuits pagination once n items are consumed.
let loadStream = table =>
  id => {
    let baseParams: QueryCommand.input = {
      tableName: table.name,
      consistentRead: true,
      keyConditionExpression: "id=:id",
      expressionAttributeValues: [(":id", id->JSON.Encode.string)]->Dict.fromArray,
    }
    Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
      Effect.tryPromise(
        ~catch=DynamoDb_Error.classify,
        () => {
          let params = switch cursor {
          | None => baseParams
          | Some(key) => {...baseParams, exclusiveStartKey: key}
          }
          QueryCommand.send(params->QueryCommand.make)
        },
      )
      ->Effect.retry(DynamoDb_Error.retrySchedule)
      ->Effect.catchAll(err =>
        Effect.fail(
          ReventlessInfra.QueryDb.NotLoadedFromStorage(DynamoDb_Error.message(err)),
        )
      )
      ->Effect.map(result => (
        result.items
        ->Option.getOr([])
        ->Array.map(js => js->JSON.stringifyAny->Option.getOr("")->JSON.parseOrThrow),
        result.lastEvaluatedKey->Option.map(key => Some(key)),
      ))
    )
  }

// Eager load derived from loadStream — collects all items into an array.
let load = table =>
  id =>
    loadStream(table)(id)
    ->Stream.runCollect
    ->Effect.map(arr => arr->Ok)
    ->Effect.catchAll(err => {
      let tableName = table.name
      let msg = ReventlessCore.QueryDb.storageErrorToString(err)
      Effect.logError(
        __MODULE__ ++ `.load: Error: Couldn't load state for ${id} from ${tableName}: ${msg}`,
      )
      ->Effect.map(_ => Error(err))
    })
    ->Effect.runPromise

let save = table =>
  (id, json, saveMode: ReventlessCore.QueryDb.saveMode, ttl) => {
    let tableName = table.name
    let json = json->insertTtl(ttl)

    let effect = switch saveMode {
    | Init =>
      table->putIfNotExistsWithRetries(~idKey=table.hashKey, ~sortKey=?table.rangeKey, id, json)
      ->Effect.flatMap(result =>
        switch result {
        | Ok() =>
          Effect.logInfo(__MODULE__ ++ `.save: saved Init state to ${tableName}: id=${id}`)
          ->Effect.map(_ => Ok())
        | Error(errorMsg) =>
          Effect.logInfo(
            __MODULE__ ++
            `.save: Error: Couldn't save Init state to ${tableName}, id=${id}: ${errorMsg}`,
          )
          ->Effect.map(_ => Error(ReventlessInfra.QueryDb.NotSavedToStorage(errorMsg)))
        }
      )
    | Any
    | Overwrite =>
      table
      ->putWithRetries(id, json)
      ->Effect.flatMap(result =>
        switch result {
        | Ok() =>
          Effect.logInfo(__MODULE__ ++ `.save: saved state to ${tableName}: id=${id}`)
          ->Effect.map(_ => Ok())
        | Error(errorMsg) =>
          Effect.logInfo(
            __MODULE__ ++
            `.save: Error: Couldn't save state to ${tableName}, id=${id}: ${errorMsg}`,
          )
          ->Effect.map(_ => Error(ReventlessInfra.QueryDb.NotSavedToStorage(errorMsg)))
        }
      )
    }
    effect->Effect.runPromise
  }

let sliceBatch = (arr, batchNr) => {
  let start = batchNr * BatchWriteCommand.maxBatchSize
  let end = start + BatchWriteCommand.maxBatchSize
  arr->Array.slice(~start, ~end)
}

let writeMultiple = (writeRequests, op, ids, table) => {
  let tableName = table.name
  let count = ids->Array.length->Int.toString
  let allIdsStr = ids->Array.joinUnsafe(", ")
  let size = writeRequests->Array.length
  let batches = (size->Int.toFloat /. BatchWriteCommand.maxBatchSize->Int.toFloat)->Math.Int.ceil

  let logSplitEffect =
    if batches > 1 {
      Effect.logInfo(
        __MODULE__ ++
        `writeBatch: splitting up batch of size ${size->Int.toString} into ${batches->Int.toString} batches`,
      )
    } else {
      Effect.succeed()
    }

  let batchEffects =
    Array.fromInitializer(~length=batches, batchNr =>
      writeRequests
      ->sliceBatch(batchNr)
      ->toTable(tableName)
      ->batchWriteWithRetries
      ->Effect.map(result => {
        let batchIds = ids->sliceBatch(batchNr)
        let batchCount = batchIds->Array.length->Int.toString
        let batchIdsStr = batchIds->Array.joinUnsafe(", ")
        switch result {
        | Ok() => None
        | Error(error) =>
          Some(`Batch ${batchNr->Int.toString}: ${batchCount} ids:${batchIdsStr}: ${error}`)
        }
      })
    )

  logSplitEffect
  ->Effect.flatMap(_ =>
    Effect.all(batchEffects, {"concurrency": "unbounded"})
  )
  ->Effect.map(results => results->Array.filterMap(x => x))
  ->Effect.flatMap(errors =>
    switch errors {
    | [] =>
      Effect.logInfo(
        __MODULE__ ++ `.writeBatch: ${op} ${count} states: ${tableName}, ids:${allIdsStr}`,
      )
      ->Effect.map(_ => Ok())
    | errors =>
      let errorsStr = errors->Array.joinUnsafe("; ")
      let errorMsg =
        __MODULE__ ++ `.writeBatch: Error: Couldn't save states to ${tableName}: ${errorsStr}`
      Effect.logError(errorMsg)
      ->Effect.map(_ => Error(ReventlessInfra.QueryDb.BatchNotFullyWrittenToStorage(errorMsg)))
    }
  )
  ->Effect.catchAll(err => {
    let msg = DynamoDb_Error.message(err)
    let errorMsg =
      __MODULE__ ++
      `.writeBatch: Error: Couldn't save states to ${tableName}, ${count} ids:${allIdsStr}: ${msg}`
    Effect.logError(errorMsg)
    ->Effect.map(_ => Error(ReventlessInfra.QueryDb.BatchNotFullyWrittenToStorage(errorMsg)))
  })
  ->Effect.runPromise
}

let saveBatch = table =>
  async items =>
    switch items {
    | [] => Ok()
    | [(id, json, ttl)] => await save(table)(id, json, Any, ttl)
    | items =>
      let _tableName = table.name
      let ids = items->Array.map(((id, _, _)) => id)
      await items
      ->Array.map(((_id, json, ttl)) => {
        json->insertTtl(ttl)->toPutRequest
      })
      ->writeMultiple("finished put", ids, table)
    }

let count = table =>
  (id, fieldName, inc) => {
    let tableName = table.name
    Effect.logInfo(
      __MODULE__ ++ `.count: ${tableName}, ${id}, ${fieldName}, ${inc->Int.toString}`,
    )
    ->Effect.flatMap(_ =>
      Effect.tryPromise(
        ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "count"),
        () =>
          UpdateCommand.make({
            tableName,
            key: [("id", id->JSON.Encode.string)]->Dict.fromArray,
            updateExpression: "ADD #fieldName :inc",
            expressionAttributeNames: [("#fieldName", fieldName)]->Dict.fromArray,
            expressionAttributeValues: [(":inc", inc->Int.toFloat->JSON.Encode.float)]
            ->Dict.fromArray,
            returnValues: #UPDATED_NEW,
          })->UpdateCommand.send,
      )
    )
    ->Effect.flatMap(updateOutput =>
      switch updateOutput.attributes->AwsSdk.DynamoDb.DocumentClient.getIntAttribute("count") {
      | Some(value) => Effect.succeed(Ok(value))
      | None =>
        Effect.logError(
          __MODULE__ ++ `.count: Error: Invalid updateOutput in count on ${tableName}`,
        )
        ->Effect.map(_ =>
          Error(ReventlessInfra.QueryDb.NotCountedOnStorage("Invalid updateOutput in count"))
        )
      }
    )
    ->Effect.catchAll(errorMsg =>
      Effect.logError(__MODULE__ ++ `.count: Error: Couldn't count on ${tableName}: ${errorMsg}`)
      ->Effect.map(_ => Error(ReventlessInfra.QueryDb.NotCountedOnStorage(errorMsg)))
    )
    ->Effect.runPromise
  }

let delete = table =>
  (id, sort) => {
    let tableName = table.name
    table
    ->deleteWithRetries(id, ~sort?)
    ->Effect.flatMap(result =>
      switch result {
      | Ok() =>
        Effect.logInfo(
          __MODULE__ ++
          `.delete: deleted state from ${tableName}: id=${id}, sort=${sort->JSON.stringifyAny->Option.getOr("None")}`,
        )
        ->Effect.map(_ => Ok())
      | Error(errorMsg) =>
        Effect.logError(
          __MODULE__ ++
          `.delete: Error: Couldn't delete state from ${tableName}, id=${id}, sort=${sort->JSON.stringifyAny->Option.getOr("None")}: ${errorMsg}`,
        )
        ->Effect.map(_ => Error(ReventlessInfra.QueryDb.NotDeletedFromStorage(errorMsg)))
      }
    )
    ->Effect.runPromise
  }

let deleteBatch = table =>
  async items =>
    switch items {
    | [] => Ok()
    | [(id, sort)] => await delete(table)(id, sort)
    | items =>
      let _tableName = table.name
      let ids = items->Array.map(((id, _)) => id)
      await items
      ->Array.map(((id, sort)) =>
        switch sort {
        | Some((sortField, sortKey)) =>
          [("id", id->JSON.Encode.string), (sortField, sortKey->JSON.Encode.string)]
          ->Dict.fromArray
          ->toDeleteRequest
        | None => [("id", id->JSON.Encode.string)]->Dict.fromArray->toDeleteRequest
        }
      )
      ->writeMultiple("deleted", ids, table)
    }
