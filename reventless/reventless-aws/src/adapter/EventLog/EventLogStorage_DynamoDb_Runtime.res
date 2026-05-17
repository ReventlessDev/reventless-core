open Util_DynamoDb_Runtime
open AwsSdk.DynamoDb.DocumentClient

// `position` is a DynamoDB reserved keyword, so the ConditionExpression
// references it via the `#p` placeholder declared in ExpressionAttributeNames.
let positionAttrNames = [("#p", "position")]->Dict.fromArray

let putItemConditional = (tableName, json) =>
  {
    PutCommand.tableName,
    item: json,
    conditionExpression: "attribute_not_exists(#p)",
    expressionAttributeNames: positionAttrNames,
  }
  ->PutCommand.make
  ->PutCommand.send

let buildTransactItems = (tableName, jsons) =>
  jsons->Array.map(json => {
    TransactWriteCommand.put: {
      TransactWriteCommand.item: json,
      tableName,
      conditionExpression: "attribute_not_exists(#p)",
      expressionAttributeNames: positionAttrNames,
    },
  })

let transactWriteConditional = (tableName, jsons) => {
  let input: TransactWriteCommand.input = {
    transactItems: buildTransactItems(tableName, jsons),
  }
  Effect.tryPromise(
    ~catch=DynamoDb_Error.classify,
    () => input->TransactWriteCommand.send,
  )->Effect.map(_ => Ok())
}

let appendWithCondition = (tableName, jsons) => {
  let count = jsons->Array.length
  if count > 100 {
    Effect.succeed(
      Error(
        `EventLog.append: max 100 events per command, got ${count->Int.toString}`,
      ),
    )
  } else if count == 1 {
    Effect.tryPromise(
      ~catch=DynamoDb_Error.classify,
      () => putItemConditional(tableName, jsons->Array.getUnsafe(0)),
    )->Effect.map(_ => Ok())
  } else {
    transactWriteConditional(tableName, jsons)
  }
}

let append = table =>
  (_sequenceNr, _id, jsons) =>
    appendWithCondition(table.name, jsons)
    ->Effect.catchAll(err =>
      switch err {
      | DynamoDb_Error.StaleState(_) => Effect.succeed(Error("conflict"))
      | _ =>
        let msg = DynamoDb_Error.message(err)
        Effect.succeed(Error(`DynamoDB conditional append failed: ${msg}`))
      }
    )
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

// Appends each stream item sequentially via conditional PutItem.
// Node.js is single-threaded so a plain ref is safe for the seqNr counter.
let appendStream = table =>
  (startingSeqNr, _id, stream) => {
    let seqNrRef = ref(startingSeqNr)
    stream->Stream.runForEach(json =>
      Effect.tryPromise(
        ~catch=DynamoDb_Error.classify,
        () => putItemConditional(table.name, json),
      )
      ->Effect.map(_ => {
        seqNrRef := seqNrRef.contents + 1
      })
      ->Effect.catchAll(err =>
        switch err {
        | DynamoDb_Error.StaleState(_) => Effect.fail("conflict")
        | _ =>
          let msg = DynamoDb_Error.message(err)
          Effect.fail(`DynamoDB appendStream error: ${msg}`)
        }
      )
    )
  }
