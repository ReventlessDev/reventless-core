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
      ReventlessCore.Logger.error("Error: unprocessed items:", unprocessedItems)
      Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries resulted in unprocessed items !")
    | exception _ => Error("AwsSdk.DynamoDb.DocumentClient.batchWriteWithRetries failed !") // TODO: error message
    }
  }

let rec tryReplay = async (~retry=0, tableName, id) =>
  switch await AwsSdk.DynamoDb.DocumentClient.queryById(tableName, id) {
  | exception JsExn(e) =>
    ReventlessCore.Logger.warn(
      ~loc=__LOC__,
      `Couldn't replay events for id ${id}, retry:${retry->Int.toString}`,
      e,
    )
    let timeout = 100 * retry + Math.Int.random(0, 100)
    await ReventlessCore.Util.Promise.finishTimeout(timeout)
    await tableName->tryReplay(~retry=retry + 1, id)
  | history => history
  }

let replay = table => {
  async id => await tryReplay(table.name, id)
}

// Wraps the existing replay (with its own retry logic) as a lazy stream.
// Full pagination will be added when queryByIdPage is implemented.
let replayStream = table =>
  id =>
    Effect.tryPromise(
      ~catch=(err: unknown) =>
        (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("DynamoDB replay error"),
      () => tryReplay(table.name, id),
    )
    ->Stream.fromEffect
    ->Stream.flatMap(arr => Stream.fromIterable(arr))

// Appends each stream item sequentially via the existing per-item append.
// Node.js is single-threaded so a plain ref is safe for the seqNr counter.
let appendStream = table =>
  (startingSeqNr, id, stream) => {
    let seqNrRef = ref(startingSeqNr)
    stream->Stream.runForEach(json =>
      Effect.tryPromise(
        ~catch=(err: unknown) =>
          (err->Obj.magic: JsExn.t)->JsExn.message->Option.getOr("DynamoDB appendStream error"),
        () => append(table)(seqNrRef.contents, id, [json]),
      )
      ->Effect.flatMap(result =>
        switch result {
        | Ok() =>
          seqNrRef := seqNrRef.contents + 1
          Effect.succeed(())
        | Error(msg) => Effect.fail(msg)
        }
      )
    )
  }
