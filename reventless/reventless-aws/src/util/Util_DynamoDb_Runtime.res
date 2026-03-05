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

let putWithRetries = (table, id, item) =>
  Effect.tryPromise(~catch=DynamoDb_Error.classify, () => table->put(item))
  ->Effect.map(_ => Ok())
  ->Effect.retry(DynamoDb_Error.retrySchedule)
  ->Effect.catchAll(err =>
    switch err {
    | Transient(msg) | Permanent(msg) =>
      Effect.logError(
        __MODULE__ ++ `.putWithRetries: id=${id}: ${msg}`,
      )
      ->Effect.map(_ => Error(`put id=${id} failed: ${msg}`))
    | StaleState(msg) =>
      Effect.succeed(Error(`Stale State: id=${id}: ${msg}`))
    }
  )

let putIfNotExistsWithRetries = (~idKey, ~sortKey=?, table, id, item) =>
  Effect.tryPromise(
    ~catch=DynamoDb_Error.classify,
    () => putIfNotExists(table.name, idKey, sortKey, item),
  )
  ->Effect.map(_ => Ok())
  ->Effect.retry(DynamoDb_Error.retrySchedule)
  ->Effect.catchAll(err =>
    switch err {
    | StaleState(_) => Effect.succeed(Error(`Stale State: id=${id}`))
    | Transient(msg) | Permanent(msg) =>
      Effect.logError(
        __MODULE__ ++ `.putIfNotExistsWithRetries: id=${id}: ${msg}`,
      )
      ->Effect.map(_ => Error(`putIfNotExists id=${id} failed: ${msg}`))
    }
  )

let delete = (table, ~sort=?, id) => {
  delete(~tableName=table.name, ~sort?, ~id)
}

let deleteWithRetries = (~sort=?, table, id) =>
  Effect.tryPromise(
    ~catch=DynamoDb_Error.classify,
    () => table->delete(id, ~sort?),
  )
  ->Effect.map(_ => Ok())
  ->Effect.retry(DynamoDb_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = DynamoDb_Error.message(err)
    Effect.logError(
      __MODULE__ ++ `.delete: id=${id}: ${msg}`,
    )
    ->Effect.map(_ => Error(`delete id=${id} failed: ${msg}`))
  })

// Streams all items matching a QueryCommand, fetching one DynamoDB page at a time.
// Each page fetch retries independently on transient errors.
let queryStream = (params: QueryCommand.input): Stream.t<JSON.t, DynamoDb_Error.t, unit> =>
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => {
        let p = switch cursor {
        | None => params
        | Some(key) => {...params, exclusiveStartKey: key}
        }
        QueryCommand.send(p->QueryCommand.make)
      },
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.map(res => (
      res.items->Option.getOr([]),
      res.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )

// Streams all items matching a ScanCommand, fetching one DynamoDB page at a time.
// Each page fetch retries independently on transient errors.
let scanStream = (params: ScanCommand.input): Stream.t<JSON.t, DynamoDb_Error.t, unit> =>
  Stream.paginateEffect((None: option<dict<JSON.t>>), cursor =>
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => {
        let p = switch cursor {
        | None => params
        | Some(key) => {...params, exclusiveStartKey: key}
        }
        ScanCommand.send(ScanCommand.make(p))
      },
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.map(res => (
      res.items->Option.getOr([]),
      res.lastEvaluatedKey->Option.map(key => Some(key)),
    ))
  )

// Convenience wrapper: streams all events for a given id.
// Returns the stream directly — callers decide how to consume it.
let queryById = (table, id): Stream.t<JSON.t, DynamoDb_Error.t, unit> =>
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

let batchWriteWithRetries = batchWriteRequests => {
  let all = batchWriteRequests->Dict.valuesToArray->Array.flat->Array.length->Int.toString
  let rec attempt = (retry, requests) =>
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => batchWrite(requests),
    )
    ->Effect.retry(DynamoDb_Error.retrySchedule)
    ->Effect.flatMap(writeOutput =>
      if writeOutput->hasUnprocessedItems {
        let unprocessedRequests = writeOutput.BatchWriteCommand.unprocessedItems->Option.getOrThrow
        let count = unprocessedRequests->Dict.keysToArray->Array.length->Int.toString
        Effect.logInfo(
          __MODULE__ ++
          `.batchWriteWithRetries: retry ${retry->Int.toString}: ${count} unprocessed items`,
        )
        ->Effect.flatMap(_ => attempt(retry + 1, unprocessedRequests))
      } else {
        Effect.succeed(Ok())
      }
    )
    ->Effect.catchAll(err => {
      let msg = DynamoDb_Error.message(err)
      Effect.succeed(Error(`batchWrite failed ${all} requests: ${msg}`))
    })
  attempt(0, batchWriteRequests)
}

let toPutRequest: JSON.t => BatchWriteCommand.writeRequest = json => {
  {putRequest: {BatchWriteCommand.item: json}}
}

let toDeleteRequest: dict<JSON.t> => BatchWriteCommand.writeRequest = keys => {
  {deleteRequest: {BatchWriteCommand.key: keys}}
}

let toTable = (writeRequests, tableName) => Dict.fromArray([(tableName, writeRequests)])
