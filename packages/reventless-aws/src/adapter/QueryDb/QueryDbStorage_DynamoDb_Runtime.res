open AwsSdk.DynamoDb.DocumentClient
open Util_DynamoDb_Runtime
open Belt.Result
open Reventless.Util.Error

let load = table => async id =>
  switch await queryById(table, id) {
  | arr => arr->Ok
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    let tableName = table.name
    Js.log(
      __MODULE__ ++ `.load: Error: Couldn't load state for ${id} from ${tableName}: ${errorMsg}`,
    )
    Error(ReventlessSpec.QueryDb.NotLoadedFromStorage(errorMsg))
  }

let save = table => async (id, json, saveMode: Reventless.QueryDb.saveMode, ttl) => {
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
      Js.log(__MODULE__ ++ `.save: saved Init state to ${tableName}: id=${id}`)
      Ok()
    | Error(errorMsg) =>
      Js.log(
        __MODULE__ ++
        `.save: Error: Couldn't save Init state to ${tableName}, id=${id}: ${errorMsg}`,
      )
      Error(ReventlessSpec.QueryDb.NotSavedToStorage(errorMsg))
    }
  | Any
  | Overwrite =>
    switch await table->putWithRetries(id, json) {
    | Ok() =>
      Js.log(__MODULE__ ++ `.save: saved state to ${tableName}: id=${id}`)
      Ok()
    | Error(errorMsg) => {
        Js.log(
          __MODULE__ ++ `.save: Error: Couldn't save state to ${tableName}, id=${id}: ${errorMsg}`,
        )
        Error(ReventlessSpec.QueryDb.NotSavedToStorage(errorMsg))
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
  let count = ids->Array.length->Js.Int.toString
  let allIdsStr = ids->Js.Array2.joinWith(", ")
  let size = writeRequests->Array.length
  let batches =
    (size->float_of_int /. BatchWriteCommand.maxBatchSize->Js.Int.toFloat)->Js.Math.ceil_int
  if batches > 1 {
    Js.log(
      __MODULE__ ++
      `writeBatch: splitting up batch of size ${size->Belt.Int.toString} into ${batches->Belt.Int.toString} batches`,
    )
  }
  let results = Array.fromInitializer(~length=batches, batchNr =>
    writeRequests
    ->sliceBatch(batchNr)
    ->toTable(tableName)
    ->batchWriteWithRetries
  )->Reventless.Util.Promise.allSettled
  switch await results {
  | results =>
    let errors =
      results
      ->Array.mapWithIndex((result, batchNr) => {
        let batchIds = ids->sliceBatch(batchNr)
        let count = batchIds->Array.length->Js.Int.toString
        let batchIdsStr = batchIds->Js.Array2.joinWith(", ")
        switch (result.value, result.reason) {
        | (Some(Error(error)), _) =>
          Some(`Batch ${batchNr->Belt.Int.toString}: ${count} ids:${batchIdsStr}: ${error}`)
        | (_, Some(reason)) =>
          let error = (reason->Reventless.Util.Error.ofPromise).message
          Some(`Batch ${batchNr->Belt.Int.toString}: ${count} ids:${batchIdsStr}: ${error}`)
        | _ => None
        }
      })
      ->Belt.Array.keepMap(x => x)
    switch errors {
    | [] =>
      Js.log(__MODULE__ ++ `.writeBatch: ${op} ${count} states: ${tableName}, ids:${allIdsStr}`)
      Ok()
    | errors =>
      let errorsStr = errors->Js.Array2.joinWith("; ")
      let errorMsg =
        __MODULE__ ++ `.writeBatch: Error: Couldn't save states to ${tableName}: ${errorsStr}`
      Js.log(errorMsg)
      Error(ReventlessSpec.QueryDb.BatchNotFullyWrittenToStorage(errorMsg))
    }
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(
      __MODULE__ ++
      `.writeBatch: Error: Couldn't save states to ${tableName}, ${count} ids:${allIdsStr}: ${errorMsg}`,
    )
    Error(ReventlessSpec.QueryDb.BatchNotFullyWrittenToStorage(errorMsg))
  }
}

let saveBatch = table => async items =>
  switch items {
  | [] => Ok()
  | [(id, json, ttl)] => await save(table)(id, json, Any, ttl)
  | items =>
    let tableName = table.name
    let ids = items->Array.map(((id, _, _)) => id)
    await items
    ->Array.map(((_id, json, ttl)) => {
      json->insertTtl(ttl)->toPutRequest
    })
    ->writeMultiple("finished put", ids, table)
  }

let count = table => async (id, fieldName, inc) => {
  let tableName = table.name
  Js.log(__MODULE__ ++ `.count: ${tableName}, ${id}, ${fieldName}, ${inc->Belt.Int.toString}`)
  switch await UpdateCommand.make({
    tableName,
    key: [("id", id->Js.Json.string)]->Js.Dict.fromArray,
    updateExpression: "ADD #fieldName :inc",
    expressionAttributeNames: [("#fieldName", fieldName)]->Js.Dict.fromArray,
    expressionAttributeValues: [(":inc", inc->Belt.Int.toFloat->Js.Json.number)]->Js.Dict.fromArray,
    returnValues: #UPDATED_NEW,
  })->UpdateCommand.send {
  | updateOutput =>
    switch updateOutput.attributes->AwsSdk.DynamoDb.DocumentClient.getIntAttribute("count") {
    | Some(value) => Ok(value)
    | None => {
        Js.log(__MODULE__ ++ `.count: Error: Invalid updateOutput in count on ${tableName}`)
        Error(ReventlessSpec.QueryDb.NotCountedOnStorage("Invalid updateOutput in count"))
      }
    }

  | exception Js.Exn.Error(e) =>
    let message = e->Reventless.Util.Error.message
    Js.log2(__MODULE__ ++ `.count: Error: Couldn't count on ${tableName}`, e)
    Error(ReventlessSpec.QueryDb.NotCountedOnStorage(message))
  }
}

let delete = table => async (id, sort) => {
  let tableName = table.name
  switch await table->deleteWithRetries(id, ~sort?) {
  | Ok() =>
    Js.log2(__MODULE__ ++ `.delete: deleted state from ${tableName}: id=${id}, sort=`, sort)
    Ok()
  | Error(errorMsg) =>
    Js.log3(
      __MODULE__ ++ `.delete: Error: Couldn't delete state from ${tableName}, id=${id}, sort=`,
      sort,
      errorMsg,
    )
    Error(ReventlessSpec.QueryDb.NotDeletedFromStorage(errorMsg))
  }
}

let deleteBatch = table => async items =>
  switch items {
  | [] => Ok()
  | [(id, sort)] => await delete(table)(id, sort)
  | items =>
    let tableName = table.name
    let ids = items->Array.map(((id, _)) => id)
    await items
    ->Array.map(((id, sort)) =>
      switch sort {
      | Some((sortField, sortKey)) =>
        [("id", id->Js.Json.string), (sortField, sortKey->Js.Json.string)]
        ->Js.Dict.fromArray
        ->toDeleteRequest
      | None => [("id", id->Js.Json.string)]->Js.Dict.fromArray->toDeleteRequest
      }
    )
    ->writeMultiple("deleted", ids, table)
  }
