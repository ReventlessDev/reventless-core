open AwsSdk.DynamoDb.DocumentClient
open Util_DynamoDb_Runtime
open Belt.Result

let loadStream = table =>
  id =>
    Effect.tryPromise(
      ~catch=err =>
        Reventless.QueryDb.NotLoadedFromStorage(
          (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("DynamoDB loadStream error"),
        ),
      () => Util_DynamoDb_Runtime.queryById(table, id),
    )
    ->Stream.fromEffect
    ->Stream.flatMap(items => Stream.fromIterable(items))

let load = table =>
  async id =>
    switch await Util_DynamoDb_Runtime.queryById(table, id) {
    | arr => arr->Ok
    | exception JsExn(e) =>
      let errorMsg = e->ReventlessCore.Util.Error.message
      let tableName = table.name
      Console.log(
        __MODULE__ ++ `.load: Error: Couldn't load state for ${id} from ${tableName}: ${errorMsg}`,
      )
      Error(Reventless.QueryDb.NotLoadedFromStorage(errorMsg))
    }

let save = table =>
  async (id, json, saveMode: ReventlessCore.QueryDb.saveMode, ttl) => {
    let tableName = table.name
    let json = json->insertTtl(ttl)

    switch saveMode {
    | Init =>
      switch await table->putIfNotExistsWithRetries(
        ~idKey=table.hashKey,
        ~sortKey=?table.rangeKey,
        id,
        json,
      ) {
      | Ok() =>
        Console.log(__MODULE__ ++ `.save: saved Init state to ${tableName}: id=${id}`)
        Ok()
      | Error(errorMsg) =>
        Console.log(
          __MODULE__ ++
          `.save: Error: Couldn't save Init state to ${tableName}, id=${id}: ${errorMsg}`,
        )
        Error(Reventless.QueryDb.NotSavedToStorage(errorMsg))
      }
    | Any
    | Overwrite =>
      switch await table->putWithRetries(id, json) {
      | Ok() =>
        Console.log(__MODULE__ ++ `.save: saved state to ${tableName}: id=${id}`)
        Ok()
      | Error(errorMsg) => {
          Console.log(
            __MODULE__ ++
            `.save: Error: Couldn't save state to ${tableName}, id=${id}: ${errorMsg}`,
          )
          Error(Reventless.QueryDb.NotSavedToStorage(errorMsg))
        }
      }
    }
  }

let sliceBatch = (arr, batchNr) => {
  let start = batchNr * BatchWriteCommand.maxBatchSize
  let end = start + BatchWriteCommand.maxBatchSize
  arr->Array.slice(~start, ~end)
}

let writeMultiple = async (writeRequests, op, ids, table) => {
  let tableName = table.name
  let count = ids->Array.length->Int.toString
  let allIdsStr = ids->Array.joinUnsafe(", ")
  let size = writeRequests->Array.length
  let batches = (size->Int.toFloat /. BatchWriteCommand.maxBatchSize->Int.toFloat)->Math.Int.ceil
  if batches > 1 {
    Console.log(
      __MODULE__ ++
      `writeBatch: splitting up batch of size ${size->Int.toString} into ${batches->Int.toString} batches`,
    )
  }
  let results = Array.fromInitializer(~length=batches, batchNr =>
    writeRequests
    ->sliceBatch(batchNr)
    ->toTable(tableName)
    ->batchWriteWithRetries
  )->ReventlessCore.Util.Promise.allSettled
  switch await results {
  | results =>
    let errors =
      results
      ->Array.mapWithIndex((result, batchNr) => {
        let batchIds = ids->sliceBatch(batchNr)
        let count = batchIds->Array.length->Int.toString
        let batchIdsStr = batchIds->Array.joinUnsafe(", ")
        switch (result.value, result.reason) {
        | (Some(Error(error)), _) =>
          Some(`Batch ${batchNr->Int.toString}: ${count} ids:${batchIdsStr}: ${error}`)
        | (_, Some(reason)) =>
          let error = switch reason {
          | JsExn(e) => e->JsExn.message->Option.getOr("Unknown error")
          | _ => "Unknown error"
          }
          Some(`Batch ${batchNr->Int.toString}: ${count} ids:${batchIdsStr}: ${error}`)
        | _ => None
        }
      })
      ->Array.filterMap(x => x)
    switch errors {
    | [] =>
      Console.log(
        __MODULE__ ++ `.writeBatch: ${op} ${count} states: ${tableName}, ids:${allIdsStr}`,
      )
      Ok()
    | errors =>
      let errorsStr = errors->Array.joinUnsafe("; ")
      let errorMsg =
        __MODULE__ ++ `.writeBatch: Error: Couldn't save states to ${tableName}: ${errorsStr}`
      Console.log(errorMsg)
      Error(Reventless.QueryDb.BatchNotFullyWrittenToStorage(errorMsg))
    }
  | exception JsExn(e) =>
    let errorMsg = e->ReventlessCore.Util.Error.message
    Console.log(
      __MODULE__ ++
      `.writeBatch: Error: Couldn't save states to ${tableName}, ${count} ids:${allIdsStr}: ${errorMsg}`,
    )
    Error(Reventless.QueryDb.BatchNotFullyWrittenToStorage(errorMsg))
  }
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
  async (id, fieldName, inc) => {
    let tableName = table.name
    Console.log(__MODULE__ ++ `.count: ${tableName}, ${id}, ${fieldName}, ${inc->Int.toString}`)
    switch await UpdateCommand.make({
      tableName,
      key: [("id", id->JSON.Encode.string)]->Dict.fromArray,
      updateExpression: "ADD #fieldName :inc",
      expressionAttributeNames: [("#fieldName", fieldName)]->Dict.fromArray,
      expressionAttributeValues: [(":inc", inc->Int.toFloat->JSON.Encode.float)]->Dict.fromArray,
      returnValues: #UPDATED_NEW,
    })->UpdateCommand.send {
    | updateOutput =>
      switch updateOutput.attributes->AwsSdk.DynamoDb.DocumentClient.getIntAttribute("count") {
      | Some(value) => Ok(value)
      | None => {
          Console.log(__MODULE__ ++ `.count: Error: Invalid updateOutput in count on ${tableName}`)
          Error(Reventless.QueryDb.NotCountedOnStorage("Invalid updateOutput in count"))
        }
      }

    | exception JsExn(e) =>
      let message = e->ReventlessCore.Util.Error.message
      Console.log2(__MODULE__ ++ `.count: Error: Couldn't count on ${tableName}`, e)
      Error(Reventless.QueryDb.NotCountedOnStorage(message))
    }
  }

let delete = table =>
  async (id, sort) => {
    let tableName = table.name
    switch await table->deleteWithRetries(id, ~sort?) {
    | Ok() =>
      Console.log2(__MODULE__ ++ `.delete: deleted state from ${tableName}: id=${id}, sort=`, sort)
      Ok()
    | Error(errorMsg) =>
      Console.log3(
        __MODULE__ ++ `.delete: Error: Couldn't delete state from ${tableName}, id=${id}, sort=`,
        sort,
        errorMsg,
      )
      Error(Reventless.QueryDb.NotDeletedFromStorage(errorMsg))
    }
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
