open AwsSdk.DynamoDb.DocumentClient
open Util_DynamoDb_Runtime
open Belt.Result
//open Reventless.QueryDb
open Reventless.Util.Error

let load = table =>
  async (. id) =>
    switch await table["name"]->Pulumi.Output.get->queryByIdWithTableName(id) {
    | arr => arr->Ok
    | exception err => {
        let tableName = table["name"]->Pulumi.Output.get
        Js.log2(__MODULE__ ++ `.load: Error: Couldn't load state for ${id} from ${tableName}`, err)

        Error(ReventlessSpec.QueryDb.NotLoadedFromStorage("")) // TODO: error message
      }
    }

let save = table =>
  async (. _id, json, saveMode: ReventlessSpec.QueryDb.saveMode, ttl) => {
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
        Js.log(__MODULE__ ++ `.save: save Init state to ${tableName}: ${stateStr}`)
        Ok()
      | exception Js.Exn.Error(e) =>
        let tableName = table["name"]->Pulumi.Output.get
        switch e->PutError.classify {
        | ConditionCheckFailedException(err) =>
          Js.log2(
            __MODULE__ ++
            `.save: Error: Stale State in ${tableName} when trying to save: ${stateStr}. error:`,
            err,
          )
          Error(ReventlessSpec.QueryDb.StaleState)
        | _ =>
          Js.log2(__MODULE__ ++ `.save: Error: Couldn't save Init state to ${tableName}`, e)
          Error(
            ReventlessSpec.QueryDb.NotSavedToStorage(
              e->Js.Exn.message->Belt.Option.getWithDefault("unknown error"),
            ),
          )
        }
      }
    | Any
    | Overwrite =>
      switch await PutCommand.make({tableName, item: json})->PutCommand.send {
      | _ =>
        Js.log(__MODULE__ ++ `.save: save state to ${tableName}: ${stateStr}`)
        Ok()

      | exception Js.Exn.Error(e) => {
          Js.log2(__MODULE__ ++ `.save: Error: Couldn't save state to ${tableName}:`, e)
          Error(
            ReventlessSpec.QueryDb.NotSavedToStorage(
              e->Js.Exn.message->Belt.Option.getWithDefault("unknown error"),
            ),
          )
        }
      }
    }
  }

@ocaml.doc(" writeChunk: max. batch size is 25 ")
let writeChunk = async (writeRequests, maxRetries) => {
  switch await writeRequests->batchWriteWithRetries(maxRetries) {
  | Error(failedRequests) =>
    let count =
      failedRequests->Belt.Option.mapWithDefault(0, requests =>
        requests->Js.Dict.keys->Belt.Array.length
      )
    `${count->Belt.Int.toString} request(s) failed after ${maxRetries->Belt.Int.toString}`->Error
  | Ok() => Ok()
  }
}

let writeBatch = async (writeRequests, table, maxRetries) => {
  let tableName = table["name"]->Pulumi.Output.get
  let batchSize = writeRequests->Belt.Array.size
  let chunks =
    (batchSize->float_of_int /. BatchWriteCommand.maxBatchSize->Js.Int.toFloat)->Js.Math.ceil_int
  if chunks > 1 {
    Js.log(
      `writeBatch: splitting up batch of size ${batchSize->Belt.Int.toString} into ${chunks->Belt.Int.toString} chunks`,
    )
  }
  let results =
    await Belt.Array.makeBy(chunks, chunkNr =>
      writeRequests
      ->Belt.Array.slice(
        ~offset=chunkNr * BatchWriteCommand.maxBatchSize,
        ~len=BatchWriteCommand.maxBatchSize,
      )
      ->toTable(tableName)
      ->writeChunk(maxRetries)
    )->Reventless.Util.Promise.allSettled
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
  | [] => Ok()
  | errors =>
    errors->Js.Array2.joinWith(",")->ReventlessSpec.QueryDb.BatchNotFullyWrittenToStorage->Error
  }
}

let saveBatch: (
  ~maxRetries: int=?,
  PulumiAws.DynamoDb.Table.t,
) => (
  . array<(string, Js.Json.t, option<int>)>,
) => Js.Promise.t<Belt.Result.t<unit, ReventlessSpec.QueryDb.storageError>> = (
  ~maxRetries=3,
  table,
) =>
  async (. items) =>
    switch items {
    | [] => Ok()
    | [(id, json, ttl)] => await save(table)(. id, json, Any, ttl)
    | items =>
      let tableName = table["name"]->Pulumi.Output.get
      await items
      ->Belt.Array.map(((_id, json, ttl)) => {
        let stateStr = json->Js.Json.stringify
        Js.log(__MODULE__ ++ `.saveBatch: save state to ${tableName}: ${stateStr}`)
        json->insertTtl(ttl)->toPutRequest
      })
      ->writeBatch(table, maxRetries)
    }

let count = table =>
  async (. id, fieldName, inc) => {
    let tableName = table["name"]->Pulumi.Output.get
    Js.log(__MODULE__ ++ `.count: ${tableName}, ${id}, ${fieldName}, ${inc->Belt.Int.toString}`)
    switch await UpdateCommand.make({
      tableName,
      key: [("id", id->Js.Json.string)]->Js.Dict.fromArray,
      updateExpression: "ADD #fieldName :inc",
      expressionAttributeNames: [("#fieldName", fieldName)]->Js.Dict.fromArray,
      expressionAttributeValues: [
        (":inc", inc->Belt.Int.toFloat->Js.Json.number),
      ]->Js.Dict.fromArray,
      returnValues: UpdatedNew,
    })->UpdateCommand.send {
    | updateOutput =>
      Ok(
        updateOutput.attributes
        ->Js.Dict.get("count")
        ->Belt.Option.map(c => c->Js.Json.decodeNumber),
      )
    | exception Js.Exn.Error(e) =>
      let message = e->Reventless.Util.Error.message
      Js.log2(__MODULE__ ++ `.count: Error: Couldn't count on ${tableName}`, e)
      Error(ReventlessSpec.QueryDb.NotCountedOnStorage(message))
    }
  }

let delete = table =>
  async (. id, sort) => {
    let tableName = table["name"]->Pulumi.Output.get
    Js.log4(
      __MODULE__ ++ ".delete: tableName, id, sort",
      table["name"]->Pulumi.Output.get,
      id,
      sort,
    )
    switch await AwsSdk.DynamoDb.DocumentClient.deleteWithTableName(~tableName, ~id, ~sort?) {
    | _ =>
      Js.log(__MODULE__ ++ `.delete: delete state for ${id} from ${tableName}`)
      Ok()

    | exception Js.Exn.Error(e) =>
      let message = e->Reventless.Util.Error.message
      Js.log2(__MODULE__ ++ `.delete: Error: Couldn't delete state for ${id} from ${tableName}`, e)
      Error(ReventlessSpec.QueryDb.NotDeletedFromStorage(message))
    }
  }

let deleteBatch = (~maxRetries=3, table) =>
  async (. ids) =>
    switch ids {
    | [] => Ok()
    | [(id, sort)] => await delete(table)(. id, sort)
    | ids =>
      let tableName = table["name"]->Pulumi.Output.get
      await ids
      ->Belt.Array.map(((id, sort)) =>
        switch sort {
        | Some((sortField, sortKey)) =>
          Js.log(
            __MODULE__ ++
            `.deleteBatch: delete state for ${id} (${sortField}=sortKey) from ${tableName}`,
          )
          [("id", id->Js.Json.string), (sortField, sortKey->Js.Json.string)]
          ->Js.Dict.fromArray
          ->toDeleteRequest
        | None =>
          Js.log(__MODULE__ ++ `.deleteBatch: delete state for ${id} from ${tableName}`)
          [("id", id->Js.Json.string)]->Js.Dict.fromArray->toDeleteRequest
        }
      )
      ->writeBatch(table, maxRetries)
    }
