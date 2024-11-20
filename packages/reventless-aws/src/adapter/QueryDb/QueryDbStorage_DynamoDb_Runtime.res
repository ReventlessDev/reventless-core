open AwsSdk.DynamoDb.DocumentClient
open Util_DynamoDb_Runtime
open Belt.Result
//open Reventless.QueryDb
open Reventless.Util.Error

let load = table => async (. id) =>
  switch await table["name"]->Pulumi.Output.get->queryByIdWithTableName(id) {
  | arr => arr->Ok
  | exception err => {
      let tableName = table["name"]->Pulumi.Output.get
      Js.log2(__MODULE__ ++ `.load: Error: Couldn't load state for ${id} from ${tableName}`, err)

      Error(ReventlessSpec.QueryDb.NotLoadedFromStorage("")) // TODO: error message
    }
  }

let save = table => async (. id, json, saveMode: ReventlessSpec.QueryDb.saveMode, ttl) => {
  let tableName = table["name"]->Pulumi.Output.get
  let stateStr = json->Js.Json.stringify
  let json = json->insertTtl(ttl)

  switch saveMode {
  | Init =>
    switch await tableName->putIfNotExists(
      table["hashKey"]->Pulumi.Output.get,
      table["rangeKey"]->Pulumi.Output.get,
      json,
    ) {
    | _ =>
      Js.log(__MODULE__ ++ `.save: saved Init state to ${tableName}: id=${id}`)
      Ok()
    | exception Js.Exn.Error(e) =>
      switch e->PutError.classify {
      | ConditionCheckFailedException(err) =>
        Js.log2(__MODULE__ ++ `.save: Error: Stale State in ${tableName}, id=${id}:`, err)
        Error(ReventlessSpec.QueryDb.StaleState)
      | _ =>
        let errorMsg = e->Reventless.Util.Error.message
        Js.log(
          __MODULE__ ++
          `.save: Error: Couldn't save Init state to ${tableName}, id=${id}: ${errorMsg}`,
        )
        Error(ReventlessSpec.QueryDb.NotSavedToStorage(errorMsg))
      }
    }
  | Any
  | Overwrite =>
    switch await PutCommand.make({tableName, item: json})->PutCommand.send {
    | _ =>
      Js.log(__MODULE__ ++ `.save: saved state to ${tableName}: id=${id}`)
      Ok()
    | exception Js.Exn.Error(e) => {
        let errorMsg = e->Reventless.Util.Error.message
        Js.log(
          __MODULE__ ++ `.save: Error: Couldn't save state to ${tableName}, id=${id}: ${errorMsg}`,
        )
        Error(ReventlessSpec.QueryDb.NotSavedToStorage(errorMsg))
      }
    }
  }
}

@ocaml.doc(" writeChunk: max. batch size is 25 ")
let writeChunk = async (writeRequests, maxRetries) => {
  switch await writeRequests->batchWriteWithRetries(maxRetries) {
  | Error(failedRequests) =>
    let count = failedRequests->Js.Dict.keys->Belt.Array.length
    `${count->Belt.Int.toString} request(s) failed after ${maxRetries->Belt.Int.toString}`->Error
  | Ok() => Ok()
  }
}

let writeBatch = async (writeRequests, op, ids, table, maxRetries) => {
  let tableName = table["name"]->Pulumi.Output.get
  let batchSize = writeRequests->Belt.Array.size
  let chunks =
    (batchSize->float_of_int /. BatchWriteCommand.maxBatchSize->Js.Int.toFloat)->Js.Math.ceil_int
  if chunks > 1 {
    Js.log(
      __MODULE__ ++
      `writeBatch: splitting up batch of size ${batchSize->Belt.Int.toString} into ${chunks->Belt.Int.toString} chunks`,
    )
  }
  let results = Belt.Array.makeBy(chunks, chunkNr =>
    writeRequests
    ->Belt.Array.slice(
      ~offset=chunkNr * BatchWriteCommand.maxBatchSize,
      ~len=BatchWriteCommand.maxBatchSize,
    )
    ->toTable(tableName)
    ->writeChunk(maxRetries)
  )->Reventless.Util.Promise.allSettled
  switch await results {
  | results =>
    let errors =
      results
      ->Belt.Array.mapWithIndex((batchNr, result) =>
        switch (result.value, result.reason) {
        | (Some(Error(error)), _) => `Batch ${batchNr->Belt.Int.toString}: ${error}`->Some
        | (_, Some(reason)) =>
          `Batch ${batchNr->Belt.Int.toString}: failed after ${maxRetries->Belt.Int.toString}: ${(
              reason->Reventless.Util.Error.ofPromise
            ).message}`->Some
        | _ => None
        }
      )
      ->Belt.Array.keepMap(x => x)
    switch errors {
    | [] =>
      Js.log(__MODULE__ ++ `.writeBatch: ${op} states: ${tableName}, ids=${ids}`)
      Ok()
    | errors =>
      let errorMsg =
        __MODULE__ ++
        `.writeBatch: failed: ${tableName}, ids=${ids}: ${errors->Js.Array2.joinWith("; ")}`
      Js.log(errorMsg)
      Error(ReventlessSpec.QueryDb.BatchNotFullyWrittenToStorage(errorMsg))
    }
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(__MODULE__ ++ `.writeBatch: failed: ${tableName}, ids=${ids}: ${errorMsg}`)
    Error(ReventlessSpec.QueryDb.BatchNotFullyWrittenToStorage(errorMsg))
  }
}

let saveBatch: (
  ~maxRetries: int=?,
  PulumiAws.DynamoDb.Table.t,
) => (
  . array<(string, Js.Json.t, option<int>)>,
) => Js.Promise.t<Belt.Result.t<unit, ReventlessSpec.QueryDb.storageError>> = (
  ~maxRetries=5,
  table,
) => async (. items) =>
  switch items {
  | [] => Ok()
  | [(id, json, ttl)] =>
    let tableName = table["name"]->Pulumi.Output.get
    await save(table)(. id, json, Any, ttl)
  | items =>
    let tableName = table["name"]->Pulumi.Output.get
    let ids = items->Belt.Array.map(((id, _, _)) => id)->Js.Array2.joinWith(",")
    await items
    ->Belt.Array.map(((_id, json, ttl)) => {
      json->insertTtl(ttl)->toPutRequest
    })
    ->writeBatch("put", ids, table, maxRetries)
  }

let count = table => async (. id, fieldName, inc) => {
  let tableName = table["name"]->Pulumi.Output.get
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

let delete = table => async (. id, sort) => {
  let tableName = table["name"]->Pulumi.Output.get
  switch await AwsSdk.DynamoDb.DocumentClient.deleteWithTableName(~tableName, ~id, ~sort?) {
  | _ =>
    Js.log2(__MODULE__ ++ `.delete: deleted state from ${tableName}: id=${id}, sort=`, sort)
    Ok()
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log3(
      __MODULE__ ++ `.delete: Error: Couldn't delete state from ${tableName}, id=${id}, sort=`,
      sort,
      errorMsg,
    )
    Error(ReventlessSpec.QueryDb.NotDeletedFromStorage(errorMsg))
  }
}

let deleteBatch = (~maxRetries=5, table) => async (. items) =>
  switch items {
  | [] => Ok()
  | [(id, sort)] => await delete(table)(. id, sort)
  | items =>
    let tableName = table["name"]->Pulumi.Output.get
    let ids = items->Belt.Array.map(((id, _)) => id)->Js.Array2.joinWith(",")
    await items
    ->Belt.Array.map(((id, sort)) =>
      switch sort {
      | Some((sortField, sortKey)) =>
        [("id", id->Js.Json.string), (sortField, sortKey->Js.Json.string)]
        ->Js.Dict.fromArray
        ->toDeleteRequest
      | None => [("id", id->Js.Json.string)]->Js.Dict.fromArray->toDeleteRequest
      }
    )
    ->writeBatch("deleted", ids, table, maxRetries)
  }
