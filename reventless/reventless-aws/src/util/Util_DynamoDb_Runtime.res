open AwsSdk.DynamoDb.DocumentClient

type runtimeTable = {
  id: string,
  name: string,
  arn: string,
  hashKey: string,
  rangeKey?: Nullable.t<string>,
}

let put = (table, item) => {
  {PutCommand.tableName: table.name, item}->PutCommand.make->PutCommand.send
}

let rec putWithRetries = async (~retry=0, ~maxRetries=5, table, id, item) =>
  switch await table->put(item) {
  | _ => Ok()
  | exception JsExn(e) =>
    let errorMsg = e->ReventlessCore.Util.Error.message
    Console.log(
      __MODULE__ ++ `.putWithRetries: id=${id}: retry ${retry->Int.toString} failed: ${errorMsg}`,
    )
    if retry < maxRetries {
      let timeout = Math.Int.random(500, 1500)
      await ReventlessCore.Util.Promise.finishTimeout(timeout)
      Console.log(`Retry put after ${timeout->Int.toString} ms`)
      await table->putWithRetries(id, item, ~retry=retry + 1, ~maxRetries)
    } else {
      Error(`put id=${id} failed after ${maxRetries->Int.toString} retries`)
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
  | exception JsExn(e) =>
    switch e->PutError.classify {
    | ConditionCheckFailedException(_err) => Error(`Stale State: id=${id}`)
    | _ =>
      let errorMsg = e->ReventlessCore.Util.Error.message
      Console.log(
        __MODULE__ ++
        `.putIfNotExistsWithRetries: id=${id}: retry ${retry->Int.toString} failed: ${errorMsg}`,
      )
      if retry < maxRetries {
        let timeout = Math.Int.random(500, 1500)
        await ReventlessCore.Util.Promise.finishTimeout(timeout)
        Console.log(`Retry putIfNotExists after ${timeout->Int.toString} ms`)
        await table->putIfNotExistsWithRetries(
          ~retry=retry + 1,
          ~maxRetries,
          ~idKey,
          ~sortKey?,
          id,
          item,
        )
      } else {
        Error(`putIfNotExists id=${id} failed after ${maxRetries->Int.toString} retries`)
      }
    }
  }

let delete = (table, ~sort=?, id) => {
  delete(~tableName=table.name, ~sort?, ~id)
}

let rec deleteWithRetries = async (~retry=0, ~maxRetries=5, ~sort=?, table, id) =>
  switch await table->delete(id, ~sort?) {
  | _ => Ok()
  | exception JsExn(e) =>
    let errorMsg = e->ReventlessCore.Util.Error.message
    Console.log(__MODULE__ ++ `.delete: id=${id}: retry ${retry->Int.toString} failed: ${errorMsg}`)
    if retry < maxRetries {
      let timeout = Math.Int.random(500, 1500)
      await ReventlessCore.Util.Promise.finishTimeout(timeout)
      Console.log(`Retry delete after ${timeout->Int.toString} ms`)
      await table->deleteWithRetries(id, ~retry=retry + 1, ~maxRetries)
    } else {
      Error(`delete id=${id} failed after ${maxRetries->Int.toString} retries`)
    }
  }

// Streams all items matching a QueryCommand, fetching one DynamoDB page at a time.
let queryStream = (params: QueryCommand.input): Stream.t<JSON.t, string, unit> =>
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=err => (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("queryStream error"),
      () => {
        let p = switch cursor {
        | None => params
        | Some(key) => {...params, exclusiveStartKey: key}
        }
        QueryCommand.send(p->QueryCommand.make)
      },
    )
    ->Effect.map(res => (
      res.items->Option.getOr([]),
      res.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )

// Streams all items matching a ScanCommand, fetching one DynamoDB page at a time.
let scanStream = (params: ScanCommand.input): Stream.t<JSON.t, string, unit> =>
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=err => (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("scanStream error"),
      () => {
        let p = switch cursor {
        | None => params
        | Some(key) => {...params, exclusiveStartKey: key}
        }
        ScanCommand.send(ScanCommand.make(p))
      },
    )
    ->Effect.map(res => (
      res.items->Option.getOr([]),
      res.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )

// Convenience wrapper: streams all events for a given id.
// Returns the stream directly — callers decide how to consume it.
let queryById = (table, id): Stream.t<JSON.t, string, unit> =>
  queryStream({
    tableName: table.name,
    consistentRead: true,
    keyConditionExpression: "id=:id",
    expressionAttributeValues: [(":id", id->JSON.Encode.string)]->Dict.fromArray,
  })

let keysFromResource: Reventless.Adapter.resource => (string, option<string>) = resource =>
  switch resource.info->Pulumi.Output.get->String.split(",") {
  | [] =>
    JsError.throwWithMessage("No id field given for table " ++ resource.name->Pulumi.Output.get)
  | [id]
  | [id, ""] => (id, None)
  | parts => (parts->Array.getUnsafe(0), parts[1])
  }

let purgeTimeAttributeName = "reventlessPurgeTime"

let calcPurgeTime = ttl => {
  let now_ms = ReventlessCore.Message.now()
  let now_s = now_ms /. 1000.0
  let now_s_rounded = now_s->Float.toInt

  (now_s_rounded + ttl)->Int.toFloat
}
let insertTtl: (JSON.t, option<int>) => JSON.t = (json, ttl) =>
  ttl
  ->Option.flatMap(ttl =>
    (
      json
      ->JSON.Decode.object
      ->Option.mapOr(
        // TODO: extract mapWithSideEffect to Util module
        () => {
          Console.log2(
            __MODULE__ ++ ".insertTtl: Error: Couldn't decode JSON",
            json->JSON.stringify,
          )
          (None: option<JSON.t>)
        },
        obj => {
          obj->Dict.set(purgeTimeAttributeName, ttl->calcPurgeTime->JSON.Encode.float)
          () => Some(obj->JSON.Encode.object)
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
    items->Dict.keysToArray->Array.length
  ) > 0

let rec retryBatchWriteIfNecessary = async (p, allItems, retry, maxRetries): result<
  unit,
  dict<array<AwsSdk.DynamoDb.DocumentClient.BatchWriteCommand.writeRequest>>,
> => {
  switch await p {
  | writeOutput =>
    if writeOutput->hasUnprocessedItems {
      let unprocessedItems = writeOutput.BatchWriteCommand.unprocessedItems->Option.getOrThrow
      let unprocessedItemsCount: string =
        unprocessedItems->Dict.keysToArray->Array.length->Int.toString
      Console.log(
        __MODULE__ ++
        `.retryBatchWriteIfNecessary: retry ${retry->Int.toString}: ${unprocessedItemsCount} unprocessed items`,
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

  | exception JsExn(e) =>
    let errorMsg = e->ReventlessCore.Util.Error.message
    Console.log(
      __MODULE__ ++ `.retryBatchWriteIfNecessary: retry ${retry->Int.toString} failed: ${errorMsg}`,
    )
    if retry < maxRetries {
      await batchWrite(allItems)->retryBatchWriteIfNecessary(allItems, retry + 1, maxRetries)
    } else {
      Error(allItems)
    }
  }
}

let rec batchWriteWithRetries = async (~retry=0, ~maxRetries=5, batchWriteRequests) => {
  let all = batchWriteRequests->Dict.valuesToArray->Array.flat->Array.length->Int.toString
  switch await batchWrite(batchWriteRequests) {
  | writeOutput =>
    if writeOutput->hasUnprocessedItems {
      let unprocessedRequests = writeOutput.BatchWriteCommand.unprocessedItems->Option.getOrThrow
      let unprocessedRequestCount: string =
        unprocessedRequests->Dict.keysToArray->Array.length->Int.toString
      Console.log(
        __MODULE__ ++
        `.batchWriteWithRetries: retry ${retry->Int.toString}: ${unprocessedRequestCount} unprocessed items`,
      )
      if retry < maxRetries {
        let timeout = Math.Int.random(500, 1500)
        await ReventlessCore.Util.Promise.finishTimeout(timeout)
        Console.log(
          `Retry batchWrite for ${unprocessedRequestCount} unprocessed items after ${timeout->Int.toString} ms`,
        )
        await batchWriteWithRetries(~retry=retry + 1, ~maxRetries, unprocessedRequests)
      } else {
        let count = batchWriteRequests->Dict.valuesToArray->Array.flat->Array.length->Int.toString
        Error(
          `batchWrite failed ${count}/${all} requests after ${maxRetries->Int.toString} retries`,
        )
      }
    } else {
      Ok()
    }
  | exception JsExn(e) =>
    let errorMsg = e->ReventlessCore.Util.Error.message
    Console.log(
      __MODULE__ ++ `.batchWriteWithRetries: retry ${retry->Int.toString} failed: ${errorMsg}`,
    )
    if retry < maxRetries {
      let timeout = Math.Int.random(500, 1500)
      await ReventlessCore.Util.Promise.finishTimeout(timeout)
      Console.log(`Retry batchWrite after ${timeout->Int.toString} ms`)
      await batchWriteWithRetries(~retry=retry + 1, ~maxRetries, batchWriteRequests)
    } else {
      Error(`batchWrite failed all ${all} requests after ${maxRetries->Int.toString} retries`)
    }
  }
}

let toPutRequest: JSON.t => BatchWriteCommand.writeRequest = json => {
  {putRequest: {BatchWriteCommand.item: json}}
}

let toDeleteRequest: dict<JSON.t> => BatchWriteCommand.writeRequest = keys => {
  {deleteRequest: {BatchWriteCommand.key: keys}}
}

let toTable = (writeRequests, tableName) => Dict.fromArray([(tableName, writeRequests)])
