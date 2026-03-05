open Util_DynamoDb_Runtime

let append = table =>
  (_sequenceNr, _id, jsons) =>
    jsons
    ->Array.map(toPutRequest)
    ->toTable(table.name)
    ->batchWriteWithRetries
    ->Effect.flatMap(result =>
      switch result {
      | Ok() => Effect.succeed(Ok())
      | Error(msg) =>
        Effect.logError("Error: unprocessed items: " ++ msg)
        ->Effect.map(_ =>
          Error(
            "AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries resulted in unprocessed items !",
          )
        )
      }
    )
    ->Effect.catchAll(msg =>
      Effect.succeed(Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries failed: " ++ msg))
    )
    ->Effect.runPromise

let tryReplay = (table, id) => {
  let rec attempt = retry =>
    queryById(table, id)
    ->Stream.runCollect
    ->Effect.catchAll(err =>
      Effect.logWarning(
        `Couldn't replay events for id ${id}, retry:${retry->Int.toString}: ` ++
        err,
      )
      ->Effect.flatMap(_ => {
        let timeout = 100 * retry + Math.Int.random(0, 100)
        Effect.sleep(Duration.millis(timeout))
        ->Effect.flatMap(_ => attempt(retry + 1))
      })
    )
  attempt(0)->Effect.runPromise
}

let replay = table => {
  async id => await tryReplay(table, id)
}

// True lazy pagination: each DynamoDB page is fetched on demand.
// Stream.take(n) short-circuits pagination once n events are consumed.
let replayStream = table =>
  id =>
    queryStream({
      tableName: table.name,
      consistentRead: true,
      keyConditionExpression: "id=:id",
      expressionAttributeValues: [(":id", id->JSON.Encode.string)]->Dict.fromArray,
    })

// Appends each stream item sequentially via the existing per-item append.
// Node.js is single-threaded so a plain ref is safe for the seqNr counter.
let appendStream = table =>
  (startingSeqNr, id, stream) => {
    let seqNrRef = ref(startingSeqNr)
    stream->Stream.runForEach(json =>
      Effect.tryPromise(
        ~catch=(err: unknown) =>
          ReventlessCore.Util.Error.messageFromUnknown(err, "DynamoDB appendStream error"),
        () => append(table)(seqNrRef.contents, id, [json]),
      )->Effect.flatMap(result =>
        switch result {
        | Ok() =>
          seqNrRef := seqNrRef.contents + 1
          Effect.succeed()
        | Error(msg) => Effect.fail(msg)
        }
      )
    )
  }
