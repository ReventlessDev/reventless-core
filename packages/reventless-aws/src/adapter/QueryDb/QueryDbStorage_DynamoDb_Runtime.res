open AwsSdk.DynamoDb.DocumentClient
open Util_DynamoDb_Runtime
open Belt.Result
open Js.Promise
open Reventless.QueryDb
open Reventless.Util.Error

let load = table =>
  (. id) =>
    table["name"]->Pulumi.Output.get->queryByIdWithTableName(id)
    |> then_(arr =>
      switch arr {
      | [] => list{}
      | items => items->Belt.List.fromArray
      }
      ->Ok
      ->resolve
    )
    |> catch(err => {
      let tableName = table["name"]->Pulumi.Output.get
      Js.log2(__MODULE__ ++ `.load: Error: Couldn't load state for ${id} from ${tableName}`, err)

      Error(NotLoadedFromStorage((err->ofPromise).message))->resolve
    })

let save = table =>
  (. _id, json, saveMode: saveMode, ttl) => {
    let tableName = table["name"]->Pulumi.Output.get
    let stateStr = json->Js.Json.stringify
    let json = json->insertTtl(ttl)

    switch saveMode {
    | Init =>
      tableName->putIfNotExists(
        table["hashKey"]->Pulumi.Output.get,
        table["rangeKey"]->Pulumi.Output.get,
        json,
      )
      |> then_(_ => {
        Js.log(__MODULE__ ++ `.save: save Init state to ${tableName}: ${stateStr}`)
        Ok()->resolve
      })
      |> catch(err => {
        let tableName = table["name"]->Pulumi.Output.get
        let err = err->ofPromise

        switch err.code {
        | "ConditionalCheckFailedException" =>
          Js.log(__MODULE__ ++ `.save: Error: Stale State in ${tableName}`)
          Error(StaleState)->resolve
        | _ =>
          Js.log2(__MODULE__ ++ `.save: Error: Couldn't save Init state to ${tableName}`, err)
          Error(NotSavedToStorage(err.message))->resolve
        }
      })
    | Any
    | Overwrite =>
      tableName->putWithTableName(json)
      |> then_(_ => {
        Js.log(__MODULE__ ++ `.save: save state to ${tableName}: ${stateStr}`)
        Ok()->resolve
      })
      |> catch(err => {
        let err = err->Reventless.Util.Error.ofPromise
        Js.log(__MODULE__ ++ `.save: Error: Couldn't save state to ${tableName}: ${err.message}`)
        Error(NotSavedToStorage(err.message))->resolve
      })
    }
  }

@ocaml.doc(" writeChunk: max. batch size is 25 ")
let writeChunk = (writeRequests, maxRetries) =>
  writeRequests->batchWriteWithRetries(maxRetries)->then_(((batchWriteItemOutput, _)) =>
    batchWriteItemOutput["_UnprocessedItems"]
    ->Js.Dict.values
    ->Belt.Array.get(0)
    ->(x =>
      switch x {
      | Some(writeRequests) =>
        let count = writeRequests->Belt.Array.length
        `${count->Belt.Int.toString} request(s) failed after ${maxRetries->Belt.Int.toString}`->Error
      | _ => Ok()
      })
    ->resolve
  , _)

let writeBatch = (writeRequests, table, maxRetries) => {
  let batchSize = writeRequests->Belt.Array.size
  let chunks = (batchSize->float_of_int /. maxBatchSize->Js.Int.toFloat)->Js.Math.ceil_int
  if chunks > 1 {
    Js.log(
      `writeBatch: splitting up batch of size ${batchSize->Belt.Int.toString} into ${chunks->Belt.Int.toString} chunks`,
    )
  }
  Belt.Array.makeBy(chunks, chunkNr =>
    writeRequests
    ->Belt.Array.slice(~offset=chunkNr * maxBatchSize, ~len=maxBatchSize)
    ->toTable(table["name"]->Pulumi.Output.get)
    ->writeChunk(maxRetries)
  )
  ->Reventless.Util.Promise.allSettled
  ->then_((results: array<Reventless.Util.Promise.result<Belt.Result.t<unit, string>>>) => {
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
    | [] => Ok()->resolve
    | errors => errors->Js.Array2.joinWith(",")->BatchNotFullyWrittenToStorage->Error->resolve
    }
  }, _)
}

let saveBatch: (
  ~maxRetries: int=?,
  PulumiAws.DynamoDb.Table.t,
) => (
  . array<(string, Js.Json.t, option<int>)>,
) => Js.Promise.t<Belt.Result.t<unit, storageError>> = (~maxRetries=3, table) =>
  (. items) =>
    switch items {
    | [] => Ok()->resolve
    | [(id, json, ttl)] => save(table)(. id, json, Any, ttl)
    | items =>
      let tableName = table["name"]->Pulumi.Output.get
      items
      ->Belt.Array.map(((_id, json, ttl)) => {
        let stateStr = json->Js.Json.stringify
        Js.log(__MODULE__ ++ `.saveBatch: save state to ${tableName}: ${stateStr}`)
        json->insertTtl(ttl)->toPutRequest
      })
      ->writeBatch(table, maxRetries)
    }

let count = table =>
  (. id, fieldName, inc) => {
    let tableName = table["name"]->Pulumi.Output.get
    Js.log(__MODULE__ ++ `.count: ${tableName}, ${id}, ${fieldName}, ${inc->Belt.Int.toString}`)
    update(
      UpdateInput.make(
        ~_TableName=tableName,
        ~_Key={"id": id},
        ~_UpdateExpression="ADD #fieldName :inc",
        ~_ExpressionAttributeNames=list{("#fieldName", fieldName)}->Js.Dict.fromList,
        ~_ExpressionAttributeValues={":inc": inc},
        ~_ReturnValues=#UPDATED_NEW,
        (),
      ),
    )
    |> then_((updateOutput: UpdateOutput.t<{"count": int}>) =>
      Ok(updateOutput["_Attributes"]["count"])->resolve
    )
    |> catch(err => {
      Js.log(
        __MODULE__ ++
        `.count: Error: Couldn't count on ${tableName}: ${(
            err->Reventless.Util.Error.ofPromise
          ).message}`,
      )
      Error(NotCountedOnStorage((err->ofPromise).message))->resolve
    })
  }

let delete = table =>
  (. id, sort) => {
    let tableName = table["name"]->Pulumi.Output.get
    Js.log4(
      __MODULE__ ++ ".delete: tableName, id, sort",
      table["name"]->Pulumi.Output.get,
      id,
      sort,
    )
    tableName->AwsSdk.DynamoDb.DocumentClient.deleteWithTableName(id, sort)
    |> then_(_ => {
      Js.log(__MODULE__ ++ `.delete: delete state for ${id} from ${tableName}`)
      Ok()->resolve
    })
    |> catch(err => {
      Js.log2(
        __MODULE__ ++ `.delete: Error: Couldn't delete state for ${id} from ${tableName}`,
        err,
      )
      Error(NotDeletedFromStorage((err->ofPromise).message))->resolve
    })
  }

let deleteBatch = (~maxRetries=3, table) =>
  (. ids) =>
    switch ids {
    | [] => Ok()->resolve
    | [(id, sort)] => delete(table)(. id, sort)
    | ids =>
      let tableName = table["name"]->Pulumi.Output.get
      ids
      ->Belt.Array.map(((id, sort)) =>
        switch sort {
        | Some((sortField, sortKey)) =>
          Js.log(
            __MODULE__ ++
            `.deleteBatch: delete state for ${id} (${sortField}=sortKey) from ${tableName}`,
          )
          list{("id", id), (sortField, sortKey)}->Js.Dict.fromList->toDeleteRequest
        | None =>
          Js.log(__MODULE__ ++ `.deleteBatch: delete state for ${id} from ${tableName}`)
          list{("id", id)}->Js.Dict.fromList->toDeleteRequest
        }
      )
      ->writeBatch(table, maxRetries)
    }
