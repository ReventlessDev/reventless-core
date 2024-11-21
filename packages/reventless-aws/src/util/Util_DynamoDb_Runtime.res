open AwsSdk.DynamoDb.DocumentClient

let service = "DynamoDb"

let put = (table: PulumiAws.DynamoDb.Table.t, item) => {
  {PutCommand.tableName: table["name"]->Pulumi.Output.get, item}->PutCommand.make->PutCommand.send
}

let rec putWithRetries = async (~retry=0, ~maxRetries=5, table, item) =>
  switch await table->put(item) {
  | _ => Ok()
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(__MODULE__ ++ `.putWithRetry: retry ${retry->Js.Int.toString} failed: ${errorMsg}`)
    if retry < maxRetries {
      await table->putWithRetries(item, ~retry=retry + 1, ~maxRetries)
    } else {
      Error(`put failed after ${maxRetries->Js.Int.toString} retries`)
    }
  }

let rec putIfNotExistsWithRetries = async (
  ~retry=0,
  ~maxRetries=5,
  ~idKey,
  ~sortKey=?,
  table,
  item,
) =>
  switch await putIfNotExists(table["name"]->Pulumi.Output.get, idKey, sortKey, item) {
  | _ => Ok()
  | exception Js.Exn.Error(e) =>
    switch e->PutError.classify {
    | ConditionCheckFailedException(err) => Error("Stale State in ${tableName}, id=${id}")
    | _ =>
      let errorMsg = e->Reventless.Util.Error.message
      Js.log(__MODULE__ ++ `.putIfNotExists: retry ${retry->Js.Int.toString} failed: ${errorMsg}`)
      if retry < maxRetries {
        await table->putIfNotExistsWithRetries(
          ~retry=retry + 1,
          ~maxRetries,
          ~idKey,
          ~sortKey?,
          item,
        )
      } else {
        Error(`putIfNotExists failed after ${maxRetries->Js.Int.toString} retries`)
      }
    }
  }

let delete = (table: PulumiAws.DynamoDb.Table.t, ~sort=?, id) => {
  delete(~tableName=table["name"]->Pulumi.Output.get, ~sort?, ~id)
}

let rec deleteWithRetries = async (~retry=0, ~maxRetries=5, ~sort=?, table, id) =>
  switch await table->delete(id, ~sort?) {
  | _ => Ok()
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(__MODULE__ ++ `.delete: retry ${retry->Js.Int.toString} failed: ${errorMsg}`)
    if retry < maxRetries {
      await table->deleteWithRetries(id, ~retry=retry + 1, ~maxRetries)
    } else {
      Error(`delete failed after ${maxRetries->Js.Int.toString} retries`)
    }
  }

let queryById = (table: PulumiAws.DynamoDb.Table.t, id) =>
  queryById(table["name"]->Pulumi.Output.get, id)

let keysFromResource: ReventlessSpec.Adapter.resource => (string, option<string>) = resource =>
  switch resource["info"]->Pulumi.Output.get->Js.String2.split(",") {
  | [] => Js.Exn.raiseError("No id field given for table " ++ resource["name"]->Pulumi.Output.get)
  | [id]
  | [id, ""] => (id, None)
  | parts => (parts[0], Some(parts[1]))
  }

let purgeTimeAttributeName = "reventlessPurgeTime"

let calcPurgeTime = ttl => {
  let now_ms = Reventless.Message.now()
  let now_s = now_ms /. 1000.0
  let now_s_rounded = now_s->int_of_float

  (now_s_rounded + ttl)->float_of_int
}
let insertTtl: (Js.Json.t, option<int>) => Js.Json.t = (json, ttl) =>
  ttl
  ->Belt.Option.flatMap(ttl =>
    (
      json
      ->Js.Json.decodeObject
      ->Belt.Option.mapWithDefault(
        // TODO: extract mapWithSideEffect to Util module
        () => {
          Js.log2(__MODULE__ ++ ".insertTtl: Error: Couldn't decode JSON", json->Js.Json.stringify)
          (None: option<Js.Json.t>)
        },
        (obj, _) => {
          obj->Js.Dict.set(purgeTimeAttributeName, ttl->calcPurgeTime->Js.Json.number)
          obj->Js.Json.object_->Some
        },
      )
    )()
  )
  ->Belt.Option.getWithDefault(json)

let batchWrite = itemRequestMap => {
  {
    requestItems: itemRequestMap,
    returnConsumedCapacity: #NONE,
    returnItemCollectionMetrics: #NONE,
  }
  ->BatchWriteCommand.make
  ->BatchWriteCommand.send
}

let hasUnprocessedItems = writeOutput =>
  writeOutput.BatchWriteCommand.unprocessedItems->Belt.Option.mapWithDefault(0, items =>
    items->Js.Dict.keys->Belt.Array.size
  ) > 0

let rec retryBatchWriteIfNecessary = async (p, allItems, retry, maxRetries): result<
  unit,
  Js.Dict.t<array<AwsSdk.DynamoDb.DocumentClient.BatchWriteCommand.writeRequest>>,
> => {
  switch await p {
  | writeOutput =>
    if writeOutput->hasUnprocessedItems {
      let unprocessedItems = writeOutput.BatchWriteCommand.unprocessedItems->Belt.Option.getExn
      let unprocessedItemsCount: string =
        unprocessedItems
        ->Js.Dict.keys
        ->Belt.Array.size
        ->Js.Int.toString
      Js.log(
        __MODULE__ ++
        `.retryBatchWriteIfNecessary: retry ${retry->Js.Int.toString}: ${unprocessedItemsCount} unprocessed items`,
      )
      if retry < maxRetries {
        await batchWrite(unprocessedItems)->retryBatchWriteIfNecessary(
          unprocessedItems,
          retry + 1,
          maxRetries,
        )
      } else {
        Error(unprocessedItems)
      }
    } else {
      Ok()
    }

  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(
      __MODULE__ ++
      `.retryBatchWriteIfNecessary: retry ${retry->Js.Int.toString} failed: ${errorMsg}`,
    )
    if retry < maxRetries {
      await batchWrite(allItems)->retryBatchWriteIfNecessary(allItems, retry + 1, maxRetries)
    } else {
      Error(allItems)
    }
  }
}

let toPutRequest: Js.Json.t => BatchWriteCommand.writeRequest = json => {
  {putRequest: {BatchWriteCommand.item: json}}
}

let toDeleteRequest: Js.Dict.t<Js.Json.t> => BatchWriteCommand.writeRequest = keys => {
  {deleteRequest: {BatchWriteCommand.key: keys}}
}

let toTable = (writeRequests, tableName) => Js.Dict.fromArray([(tableName, writeRequests)])

let batchWriteWithRetries = (batchWriteItemRequestMap, maxRetries) =>
  batchWrite(batchWriteItemRequestMap)->retryBatchWriteIfNecessary(
    batchWriteItemRequestMap,
    0,
    maxRetries,
  )

let findResource = resources => resources->Reventless.Util.AdapterRuntime.findResource(service)
