open Util_DynamoDb_Runtime

let append = table =>
  async (_sequenceNr, _id, jsons) => {
    let result =
      jsons
      ->Array.map(toPutRequest)
      ->toTable(table.name)
      ->batchWriteWithRetries
    switch await result {
    | Ok() => Ok()
    | Error(unprocessedItems) =>
      Console.error2("Error: unprocessed items:", unprocessedItems)
      Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries resulted in unprocessed items !")
    | exception _ => Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries failed !") // TODO: error message
    }
  }

let rec tryReplay = async (~retry=0, table, id) =>
  switch await queryById(table, id)->Stream.runCollect->Effect.runPromise {
  | exception err =>
    Console.warn2(`Couldn't replay events for id ${id}, retry:${retry->Int.toString}`, err)
    let timeout = 100 * retry + Math.Int.random(0, 100)
    await ReventlessCore.Util.Promise.finishTimeout(timeout)
    await tryReplay(~retry=retry + 1, table, id)
  | history => history
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
