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

let putWithRetries = (~maxRetries=5, table, id, item) => {
  let rec attempt = retry =>
    Effect.tryPromise(
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "put"),
      () => table->put(item),
    )
    ->Effect.map(_ => Ok())
    ->Effect.catchAll(errorMsg =>
      Effect.logInfo(
        __MODULE__ ++ `.putWithRetries: id=${id}: retry ${retry->Int.toString} failed: ${errorMsg}`,
      )
      ->Effect.flatMap(_ =>
        if retry < maxRetries {
          let timeout = Math.Int.random(500, 1500)
          Effect.sleep(Duration.millis(timeout))
          ->Effect.tap(_ => Effect.logInfo(`Retry put after ${timeout->Int.toString} ms`))
          ->Effect.flatMap(_ => attempt(retry + 1))
        } else {
          Effect.succeed(Error(`put id=${id} failed after ${maxRetries->Int.toString} retries`))
        }
      )
    )
  attempt(0)
}

let putIfNotExistsWithRetries = (~maxRetries=5, ~idKey, ~sortKey=?, table, id, item) => {
  let rec attempt = retry =>
    Effect.tryPromise(
      ~catch=err => {
        let jsErr: JsExn.t = Obj.magic(err)
        jsErr
      },
      () => putIfNotExists(table.name, idKey, sortKey, item),
    )
    ->Effect.map(_ => Ok())
    ->Effect.catchAll(jsErr =>
      switch jsErr->PutError.classify {
      | ConditionCheckFailedException(_) => Effect.succeed(Error(`Stale State: id=${id}`))
      | _ =>
        let errorMsg = jsErr->ReventlessCore.Util.Error.message
        Effect.logInfo(
          __MODULE__ ++
          `.putIfNotExistsWithRetries: id=${id}: retry ${retry->Int.toString} failed: ${errorMsg}`,
        )
        ->Effect.flatMap(_ =>
          if retry < maxRetries {
            let timeout = Math.Int.random(500, 1500)
            Effect.sleep(Duration.millis(timeout))
            ->Effect.tap(_ =>
              Effect.logInfo(`Retry putIfNotExists after ${timeout->Int.toString} ms`)
            )
            ->Effect.flatMap(_ => attempt(retry + 1))
          } else {
            Effect.succeed(
              Error(`putIfNotExists id=${id} failed after ${maxRetries->Int.toString} retries`),
            )
          }
        )
      }
    )
  attempt(0)
}

let delete = (table, ~sort=?, id) => {
  delete(~tableName=table.name, ~sort?, ~id)
}

let deleteWithRetries = (~maxRetries=5, ~sort=?, table, id) => {
  let rec attempt = retry =>
    Effect.tryPromise(
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "delete"),
      () => table->delete(id, ~sort?),
    )
    ->Effect.map(_ => Ok())
    ->Effect.catchAll(errorMsg =>
      Effect.logInfo(
        __MODULE__ ++ `.delete: id=${id}: retry ${retry->Int.toString} failed: ${errorMsg}`,
      )
      ->Effect.flatMap(_ =>
        if retry < maxRetries {
          let timeout = Math.Int.random(500, 1500)
          Effect.sleep(Duration.millis(timeout))
          ->Effect.tap(_ => Effect.logInfo(`Retry delete after ${timeout->Int.toString} ms`))
          ->Effect.flatMap(_ => attempt(retry + 1))
        } else {
          Effect.succeed(Error(`delete id=${id} failed after ${maxRetries->Int.toString} retries`))
        }
      )
    )
  attempt(0)
}

// Streams all items matching a QueryCommand, fetching one DynamoDB page at a time.
let queryStream = (params: QueryCommand.input): Stream.t<JSON.t, string, unit> =>
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "queryStream error"),
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
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "scanStream error"),
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

let keysFromResource: ReventlessInfra.Adapter.resource => (string, option<string>) = resource =>
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
  switch ttl {
  | None => json
  | Some(ttl) =>
    switch json->JSON.Decode.object {
    | Some(obj) =>
      obj->Dict.set(purgeTimeAttributeName, ttl->calcPurgeTime->JSON.Encode.float)
      obj->JSON.Encode.object
    | None => json
    }
  }

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

let batchWriteWithRetries = (~maxRetries=5, batchWriteRequests) => {
  let all = batchWriteRequests->Dict.valuesToArray->Array.flat->Array.length->Int.toString
  let rec attempt = (retry, requests) => {
    let handleRetry = (logMsg, retryRequests) =>
      Effect.logInfo(logMsg)
      ->Effect.flatMap(_ =>
        if retry < maxRetries {
          let timeout = Math.Int.random(500, 1500)
          Effect.sleep(Duration.millis(timeout))
          ->Effect.tap(_ => Effect.logInfo(`Retry batchWrite after ${timeout->Int.toString} ms`))
          ->Effect.flatMap(_ => attempt(retry + 1, retryRequests))
        } else {
          let count = retryRequests->Dict.valuesToArray->Array.flat->Array.length->Int.toString
          Effect.succeed(
            Error(
              `batchWrite failed ${count}/${all} requests after ${maxRetries->Int.toString} retries`,
            ),
          )
        }
      )

    Effect.tryPromise(
      ~catch=err => ReventlessCore.Util.Error.messageFromUnknown(err, "batchWrite"),
      () => batchWrite(requests),
    )
    ->Effect.flatMap(writeOutput =>
      if writeOutput->hasUnprocessedItems {
        let unprocessedRequests = writeOutput.BatchWriteCommand.unprocessedItems->Option.getOrThrow
        let count = unprocessedRequests->Dict.keysToArray->Array.length->Int.toString
        handleRetry(
          __MODULE__ ++
          `.batchWriteWithRetries: retry ${retry->Int.toString}: ${count} unprocessed items`,
          unprocessedRequests,
        )
      } else {
        Effect.succeed(Ok())
      }
    )
    ->Effect.catchAll(errorMsg =>
      handleRetry(
        __MODULE__ ++
        `.batchWriteWithRetries: retry ${retry->Int.toString} failed: ${errorMsg}`,
        requests,
      )
    )
  }
  attempt(0, batchWriteRequests)
}

let toPutRequest: JSON.t => BatchWriteCommand.writeRequest = json => {
  {putRequest: {BatchWriteCommand.item: json}}
}

let toDeleteRequest: dict<JSON.t> => BatchWriteCommand.writeRequest = keys => {
  {deleteRequest: {BatchWriteCommand.key: keys}}
}

let toTable = (writeRequests, tableName) => Dict.fromArray([(tableName, writeRequests)])
