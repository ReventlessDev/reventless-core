// CsvStream.res
// Bridges FastCSV's callback-based API to an Effect Stream.
// Rows are emitted as CSV.row (= dict<string>) using the header row as keys.
//
// Implementation: each onData callback offers its row into an unbounded Queue;
// Stream.fromQueue drains the queue lazily. This lets callers start processing
// rows as they arrive rather than waiting for the entire file to be loaded.
//
// Note: Stream.take(n) short-circuits queue consumption, but the underlying
// CSV parser runs at full speed and continues reading in the background.
// Effect.runSyncExit is used inside the onData/onError callbacks so that a
// queue that is already done (e.g. after stream interruption) never throws.
// The input is finished with Queue.endUnsafe, not shutdown: shutdown would
// discard rows the reader has not taken yet.

// Parse a CSV file, emitting one row per stream item.
// The first row is treated as column headers (not emitted as data).
// CSV parse errors are propagated through the stream's error channel.
let parseRows = (~path: string): Stream.t<CSV.row, string, unit> =>
  Queue.unbounded()
  ->Effect.flatMap(queue => {
    let _ =
      CSV.parseFile(~path, ~options={headers: CSV.Options.Bool(true)})
      ->CSV.onData(row => Queue.offer(queue, Ok(row))->Effect.runSyncExit->ignore)
      ->CSV.onEnd(_ => {
        let _ = Queue.endUnsafe(queue)
      })
      ->CSV.onError(err => {
        let msg = err->JsExn.message->Option.getOr("CSV parse error")
        Queue.offer(queue, Error(msg))->Effect.runSyncExit->ignore
        let _ = Queue.endUnsafe(queue)
      })
    Effect.succeed(queue)
  })
  ->Stream.fromEffect
  ->Stream.flatMap(queue =>
    Stream.fromQueue(queue)->Stream.mapEffect(item =>
      switch item {
      | Ok(row) => Effect.succeed(row)
      | Error(msg) => Effect.fail(msg)
      }
    )
  )
