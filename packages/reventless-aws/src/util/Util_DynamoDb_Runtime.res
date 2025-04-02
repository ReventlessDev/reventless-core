open AwsSdk.DynamoDb.DocumentClient

type runtimeTable = {
  id: string,
  name: string,
  arn: string,
  hashKey: string,
  rangeKey?: Js.Nullable.t<string>,
}

let put = (table, item) => {
  {PutCommand.tableName: table.name, item}->PutCommand.make->PutCommand.send
}

let rec putWithRetries = async (~retry=0, ~maxRetries=5, table, id, item) =>
  switch await table->put(item) {
  | _ => Ok()
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(
      __MODULE__ ++
      `.putWithRetries: id=${id}: retry ${retry->Js.Int.toString} failed: ${errorMsg}`,
    )
    if retry < maxRetries {
      let timeout = Js.Math.random_int(500, 1500)
      await Reventless.Util.Promise.finishTimeout(timeout)
      Js.log(`Retry put after ${timeout->Js.Int.toString} ms`)
      await table->putWithRetries(id, item, ~retry=retry + 1, ~maxRetries)
    } else {
      Error(`put id=${id} failed after ${maxRetries->Js.Int.toString} retries`)
    }
  }

let rec putIfNotExistsWithRetries = async (
  ~retry=0,
  ~maxRetries=5,
  ~idKey,
  ~sortKey=?,
  table,
  id,
  item,
) =>
  switch await putIfNotExists(table.name, idKey, sortKey, item) {
  | _ => Ok()
  | exception Js.Exn.Error(e) =>
    switch e->PutError.classify {
    | ConditionCheckFailedException(_err) => Error(`Stale State: id=${id}`)
    | _ =>
      let errorMsg = e->Reventless.Util.Error.message
      Js.log(
        __MODULE__ ++
        `.putIfNotExistsWithRetries: id=${id}: retry ${retry->Js.Int.toString} failed: ${errorMsg}`,
      )
      if retry < maxRetries {
        let timeout = Js.Math.random_int(500, 1500)
        await Reventless.Util.Promise.finishTimeout(timeout)
        Js.log(`Retry putIfNotExists after ${timeout->Js.Int.toString} ms`)
        await table->putIfNotExistsWithRetries(
          ~retry=retry + 1,
          ~maxRetries,
          ~idKey,
          ~sortKey?,
          id,
          item,
        )
      } else {
        Error(`putIfNotExists id=${id} failed after ${maxRetries->Js.Int.toString} retries`)
      }
    }
  }

let delete = (table, ~sort=?, id) => {
  delete(~tableName=table.name, ~sort?, ~id)
}

let rec deleteWithRetries = async (~retry=0, ~maxRetries=5, ~sort=?, table, id) =>
  switch await table->delete(id, ~sort?) {
  | _ => Ok()
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(__MODULE__ ++ `.delete: id=${id}: retry ${retry->Js.Int.toString} failed: ${errorMsg}`)
    if retry < maxRetries {
      let timeout = Js.Math.random_int(500, 1500)
      await Reventless.Util.Promise.finishTimeout(timeout)
      Js.log(`Retry delete after ${timeout->Js.Int.toString} ms`)
      await table->deleteWithRetries(id, ~retry=retry + 1, ~maxRetries)
    } else {
      Error(`delete id=${id} failed after ${maxRetries->Js.Int.toString} retries`)
    }
  }

let queryById = (table, id) => queryById(table.name, id)

let keysFromResource: ReventlessSpec.Adapter.resource => (string, option<string>) = resource =>
  switch resource.info->Pulumi.Output.get->Js.String2.split(",") {
  | [] => Js.Exn.raiseError("No id field given for table " ++ resource.name->Pulumi.Output.get)
  | [id]
  | [id, ""] => (id, None)
  | parts => (parts->Array.getUnsafe(0), parts[1])
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
  ->Option.flatMap(ttl =>
    (
      json
      ->Js.Json.decodeObject
      ->Option.mapOr(
        // TODO: extract mapWithSideEffect to Util module
        () => {
          Js.log2(__MODULE__ ++ ".insertTtl: Error: Couldn't decode JSON", json->Js.Json.stringify)
          (None: option<Js.Json.t>)
        },
        obj => {
          obj->Js.Dict.set(purgeTimeAttributeName, ttl->calcPurgeTime->Js.Json.number)
          () => Some(obj->Js.Json.object_)
        },
      )
    )()
  )
  ->Option.getOr(json)

/** max. batch size is 25 */
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
  writeOutput.BatchWriteCommand.unprocessedItems->Option.mapOr(0, items =>
    items->Js.Dict.keys->Array.length
  ) > 0

let rec retryBatchWriteIfNecessary = async (p, allItems, retry, maxRetries): result<
  unit,
  Js.Dict.t<array<AwsSdk.DynamoDb.DocumentClient.BatchWriteCommand.writeRequest>>,
> => {
  switch await p {
  | writeOutput =>
    if writeOutput->hasUnprocessedItems {
      let unprocessedItems = writeOutput.BatchWriteCommand.unprocessedItems->Option.getExn
      let unprocessedItemsCount: string =
        unprocessedItems
        ->Js.Dict.keys
        ->Array.length
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

let rec batchWriteWithRetries = async (~retry=0, ~maxRetries=5, batchWriteRequests) => {
  let all = batchWriteRequests->Js.Dict.values->Array.flat->Array.length->Js.Int.toString
  switch await batchWrite(batchWriteRequests) {
  | writeOutput =>
    if writeOutput->hasUnprocessedItems {
      let unprocessedRequests = writeOutput.BatchWriteCommand.unprocessedItems->Option.getExn
      let unprocessedRequestCount: string =
        unprocessedRequests
        ->Js.Dict.keys
        ->Array.length
        ->Js.Int.toString
      Js.log(
        __MODULE__ ++
        `.batchWriteWithRetries: retry ${retry->Js.Int.toString}: ${unprocessedRequestCount} unprocessed items`,
      )
      if retry < maxRetries {
        let timeout = Js.Math.random_int(500, 1500)
        await Reventless.Util.Promise.finishTimeout(timeout)
        Js.log(
          `Retry batchWrite for ${unprocessedRequestCount} unprocessed items after ${timeout->Js.Int.toString} ms`,
        )
        await batchWriteWithRetries(~retry=retry + 1, ~maxRetries, unprocessedRequests)
      } else {
        let count =
          batchWriteRequests
          ->Js.Dict.values
          ->Array.flat
          ->Array.length
          ->Js.Int.toString
        Error(
          `batchWrite failed ${count}/${all} requests after ${maxRetries->Js.Int.toString} retries`,
        )
      }
    } else {
      Ok()
    }
  | exception Js.Exn.Error(e) =>
    let errorMsg = e->Reventless.Util.Error.message
    Js.log(
      __MODULE__ ++ `.batchWriteWithRetries: retry ${retry->Js.Int.toString} failed: ${errorMsg}`,
    )
    if retry < maxRetries {
      let timeout = Js.Math.random_int(500, 1500)
      await Reventless.Util.Promise.finishTimeout(timeout)
      Js.log(`Retry batchWrite after ${timeout->Js.Int.toString} ms`)
      await batchWriteWithRetries(~retry=retry + 1, ~maxRetries, batchWriteRequests)
    } else {
      Error(`batchWrite failed all ${all} requests after ${maxRetries->Js.Int.toString} retries`)
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
