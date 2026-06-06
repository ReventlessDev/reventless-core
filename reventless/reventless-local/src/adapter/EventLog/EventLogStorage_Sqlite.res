// SQLite-backed event log storage.
//
// Schema (shared across all EventLogs — partitioned by log_name):
//   CREATE TABLE event_log (
//     log_name TEXT NOT NULL,
//     aggregate_id TEXT NOT NULL,
//     seq_nr INTEGER NOT NULL,
//     payload TEXT NOT NULL,  -- JSON.stringify of one event
//     PRIMARY KEY (log_name, aggregate_id, seq_nr)
//   )
//
// Optimistic concurrency: the append caller passes the seqNr that
// corresponds to "no events appended yet after my seqNr". If another caller
// raced and inserted at the same (log_name, aggregate_id, seq_nr), the PK
// conflict becomes `Error("conflict")`.

open ReventlessCore

let ensureSchema = (db: SqliteDriver.t) =>
  db->SqliteDriver.exec(
    "CREATE TABLE IF NOT EXISTS event_log (log_name TEXT NOT NULL, aggregate_id TEXT NOT NULL, seq_nr INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (log_name, aggregate_id, seq_nr))",
  )

// Decodes the JSON column to a JSON.t. Returns JSON.Null on unparseable input
// (should not happen for data we wrote ourselves).
let decodePayload = (row: dict<JSON.t>): JSON.t =>
  switch row->Dict.get("payload") {
  | Some(JSON.String(s)) =>
    switch JSON.parseOrThrow(s) {
    | json => json
    | exception _ => JSON.Encode.null
    }
  | _ => JSON.Encode.null
  }

let makeStorage = (~db: SqliteDriver.t, ~name: string, ~opts as _) => {
  ensureSchema(db)

  let insertStmt = db->SqliteDriver.prepare(
    "INSERT INTO event_log(log_name, aggregate_id, seq_nr, payload) VALUES(?,?,?,?)",
  )
  let countStmt = db->SqliteDriver.prepare(
    "SELECT COUNT(*) AS c FROM event_log WHERE log_name=? AND aggregate_id=?",
  )
  let selectByIdStmt = db->SqliteDriver.prepare(
    "SELECT payload FROM event_log WHERE log_name=? AND aggregate_id=? ORDER BY seq_nr ASC",
  )

  let currentCount = (id: string): int =>
    switch countStmt->SqliteDriver.get([JSON.Encode.string(name), JSON.Encode.string(id)]) {
    | Some(row) =>
      switch row->Dict.get("c") {
      | Some(JSON.Number(n)) => Float.toInt(n)
      | _ => 0
      }
    | None => 0
    }

  let append: EventLog.append<string, JSON.t> = async (seqNr, id, jsons) => {
    try {
      db->SqliteDriver.transaction(() => {
        let existing = currentCount(id)
        if seqNr != existing {
          throw(Failure("conflict"))
        }
        jsons->Array.forEachWithIndex((json, i) => {
          insertStmt->SqliteDriver.run([
            JSON.Encode.string(name),
            JSON.Encode.string(id),
            JSON.Encode.int(seqNr + i),
            JSON.Encode.string(JSON.stringify(json)),
          ])
        })
      })
      Ok()
    } catch {
    | Failure(msg) => Error(msg)
    | _ => Error("conflict")
    }
  }

  let replayArray = (id: string): array<JSON.t> =>
    selectByIdStmt
    ->SqliteDriver.all([JSON.Encode.string(name), JSON.Encode.string(id)])
    ->Array.map(decodePayload)

  let replay: EventLog.replay<string, JSON.t> = async id => replayArray(id)

  // node:sqlite's iterate() could back a lazy stream, but the current Stream
  // API only has array-based fromIterable. Small events, dev-only backend →
  // materialise via all() and wrap. Swap to a lazy adapter if it matters.
  let replayStream: string => Stream.t<JSON.t, string, unit> = id =>
    replayArray(id)->Stream.fromIterable

  let appendStream: EventLog.appendStream<string, JSON.t> = (startingSeqNr, id, stream) => {
    let seqNrRef = ref(startingSeqNr)
    stream->Stream.runForEach(json => {
      let currentSeq = seqNrRef.contents
      Effect.promise(() => append(currentSeq, id, [json]))->Effect.flatMap(result =>
        switch result {
        | Ok() =>
          seqNrRef := currentSeq + 1
          Effect.succeed()
        | Error(msg) => Effect.fail(msg)
        }
      )
    })
  }

  (
    name,
    replay,
    {
      EventLog_Adapter.resources: [],
      operations: Pulumi.Output.make({
        EventLog_Adapter.append,
        replay,
        replayStream,
        appendStream,
      }),
    },
  )
}

module Make = (Bus: LocalBus.T, DbProvider: {let db: SqliteDriver.t}) => {
  let make: EventLog_Adapter.storageMaker = (~name, ~opts) => {
    let (storageName, replay, storage) = makeStorage(~db=DbProvider.db, ~name, ~opts)
    Bus.registerEventLogReplay(storageName, replay)
    storage
  }
}
