// CsvStream.res
// Bridges FastCSV's callback-based API to an Effect Stream.
// Rows are emitted as CSV.row (= dict<string>) using the header row as keys.
//
// Implementation: collects all rows via a Promise bridge, then emits them as a
// stream via Stream.fromEffect → Stream.flatMap(fromIterable). This satisfies
// the functional contract for Task file-processing callbacks with moderate file sizes.
// For true per-row lazy streaming (file-read interruption on Stream.take), a
// Queue bridge or Channel wrapper would be needed.
//
// See docs/plans/effect-stream-integration.md Phase E for design context.

// Parse a CSV file, emitting one row per stream item.
// The first row is treated as column headers (not emitted as data).
// CSV parse errors are propagated through the stream's error channel.
let parseRows = (~path: string): Stream.t<CSV.row, string, unit> => {
  Effect.promise(() =>
    Promise.make((resolve, _reject) => {
      let rows: ref<array<CSV.row>> = ref([])
      let _ = CSV.parseFile(~path, ~options={headers: CSV.Options.Bool(true)})
        ->CSV.onData(row => rows := rows.contents->Array.concat([row]))
        ->CSV.onEnd(_ => resolve(Ok(rows.contents)))
        ->CSV.onError(err =>
          resolve(Error(err->JsExn.message->Option.getOr("CSV parse error")))
        )
    })
  )
  ->Effect.flatMap(result =>
    switch result {
    | Ok(rows) => Effect.succeed(rows)
    | Error(msg) => Effect.fail(msg)
    }
  )
  ->Stream.fromEffect
  ->Stream.flatMap(rows => Stream.fromIterable(rows))
}
