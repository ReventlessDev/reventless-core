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
    ->Effect.catchAll(err => {
      let msg = DynamoDb_Error.message(err)
      Effect.succeed(Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries failed: " ++ msg))
    })
    ->Effect.runPromise

// True lazy pagination: each DynamoDB page is fetched on demand.
// Per-page retry is handled inside queryStream.
// Stream.take(n) short-circuits pagination once n events are consumed.
let replayStream = table =>
  id =>
    queryStream({
      tableName: table.name,
      consistentRead: true,
      keyConditionExpression: "id=:id",
      expressionAttributeValues: [(":id", id->JSON.Encode.string)]->Dict.fromArray,
    })
    ->Stream.catchAll(err => {
      let msg = DynamoDb_Error.message(err)
      Stream.fromEffect(Effect.fail(msg))
    })

// Eager replay derived from replayStream — collects all events into an array.
let replay = table =>
  id =>
    replayStream(table)(id)
    ->Stream.runCollect
    ->Effect.catchAll(msg => {
      Effect.logError(
        `Couldn't replay events for id ${id} after retries: ${msg}`,
      )
      ->Effect.flatMap(_ => Effect.fail(msg))
    })
    ->Effect.runPromise

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
