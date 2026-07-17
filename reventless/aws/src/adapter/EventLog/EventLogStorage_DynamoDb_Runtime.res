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
    () => input->TransactWriteCommand.make->TransactWriteCommand.send,
  )->Effect.map(_ => Ok())
}

let appendWithCondition = (tableName, jsons) => {
  let count = jsons->Array.length
  if count > 100 {
    Effect.succeed(
      Error(
        ReventlessCore.EventLog.StorageFailure(
          `EventLog.append: max 100 events per command, got ${count->Int.toString}`,
        ),
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
      | DynamoDb_Error.StaleState(_) =>
        Effect.succeed(Error(ReventlessCore.EventLog.Conflict))
      | _ =>
        let msg = DynamoDb_Error.message(err)
        Effect.succeed(
          Error(ReventlessCore.EventLog.StorageFailure(`DynamoDB conditional append failed: ${msg}`)),
        )
      }
    )
    ->Effect.runPromise

// ─── Aggregate snapshots (docs/plans/aggregate-snapshotting.md) ───
// A snapshot lives in the SAME table as the events, on the reserved sort key
// `position = "SNAPSHOT"`. Event positions are 9-digit zero-padded numbers, so
// bounding the replay query to the all-digit range excludes the snapshot row
// (and "S" > "9" keeps it out of any position-ordered event scan prefix).
// Keep-one: writeSnapshot is a plain overwrite Put. The DynamoDB stream feed is
// unaffected — Util_DynamoDbStream_Runtime.buildJsonEvent' drops rows without
// an `event` column, so snapshot writes never reach event collectors.
let snapshotPosition = "SNAPSHOT"
let maxEventPosition = "999999999"
let padSeq = seq => seq->Int.toString->String.padStart(9, "0")

// Pure input builders, exposed for tests (same pattern as buildTransactItems).
let replayQueryInput = (tableName, id, ~fromSeq=0): QueryCommand.input => {
  tableName,
  consistentRead: true,
  keyConditionExpression: "id=:id AND #p BETWEEN :from AND :to",
  expressionAttributeNames: positionAttrNames,
  expressionAttributeValues: [
    (":id", id->JSON.Encode.string),
    (":from", padSeq(fromSeq)->JSON.Encode.string),
    (":to", maxEventPosition->JSON.Encode.string),
  ]->Dict.fromArray,
}

let snapshotKey = id =>
  [
    ("id", id->JSON.Encode.string),
    ("position", snapshotPosition->JSON.Encode.string),
  ]->Dict.fromArray

let snapshotItem = (id, snap: ReventlessCore.EventLog.snapshot): JSON.t =>
  [
    ("id", id->JSON.Encode.string),
    ("position", snapshotPosition->JSON.Encode.string),
    ("seqNr", snap.seqNr->JSON.Encode.int),
    ("state", snap.state),
    ("schemaHash", snap.schemaHash->JSON.Encode.string),
  ]
  ->Dict.fromArray
  ->JSON.Encode.object

let decodeSnapshotItem = (item: JSON.t): option<ReventlessCore.EventLog.snapshot> =>
  item
  ->JSON.Decode.object
  ->Option.flatMap(d =>
    switch (d->Dict.get("seqNr"), d->Dict.get("state"), d->Dict.get("schemaHash")) {
    | (Some(JSON.Number(n)), Some(state), Some(JSON.String(schemaHash))) =>
      Some({ReventlessCore.EventLog.seqNr: Float.toInt(n), state, schemaHash})
    | _ => None
    }
  )

let exnMessage = (exn, fallback) =>
  exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(fallback)

let latestSnapshot = table =>
  async id =>
    try {
      let out = await GetCommand.send(
        GetCommand.make({
          tableName: table.Util_DynamoDb_Runtime.name,
          key: snapshotKey(id),
          consistentRead: true,
        }),
      )
      switch out.item {
      | Some(item) =>
        switch decodeSnapshotItem(item) {
        | Some(snap) => Ok(Some(snap))
        | None => Error("snapshot item has unexpected shape")
        }
      | None => Ok(None)
      }
    } catch {
    | exn => Error(exnMessage(exn, "snapshot read error"))
    }

let writeSnapshot = table =>
  async (id, snap) =>
    try {
      let _ = await PutCommand.send(
        PutCommand.make({
          tableName: table.Util_DynamoDb_Runtime.name,
          item: snapshotItem(id, snap),
        }),
      )
      Ok()
    } catch {
    | exn => Error(exnMessage(exn, "snapshot write error"))
    }

// True lazy pagination: each DynamoDB page is fetched on demand.
// Per-page retry is handled inside queryStream.
// Stream.take(n) short-circuits pagination once n events are consumed.
// `fromSeq` narrows the key condition so a snapshot-seeded delta read only
// pays for the events it returns.
let replayStream = table =>
  (id, ~fromSeq=?) =>
    queryStream(replayQueryInput(table.Util_DynamoDb_Runtime.name, id, ~fromSeq=?fromSeq))
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
      ReventlessCore.EffectLogger.logError(
        ~comp=__MODULE__,
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
