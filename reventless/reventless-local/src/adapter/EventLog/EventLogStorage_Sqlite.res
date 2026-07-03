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

// Total events persisted across all aggregates in this table. Used at startup to
// seed the event-tap counter so the timeline numbering continues across restarts.
let countAll = (db: SqliteDriver.t): int => {
  ensureSchema(db)
  switch db->SqliteDriver.prepare("SELECT COUNT(*) AS c FROM event_log")->SqliteDriver.get([]) {
  | Some(row) =>
    switch row->Dict.get("c") {
    | Some(JSON.Number(n)) => Float.toInt(n)
    | _ => 0
    }
  | None => 0
  }
}

let makeStorage = (~db: SqliteDriver.t, ~name: string, ~opts as _) => {
  ensureSchema(db)

  let insertStmt = db->SqliteDriver.prepare(
    "INSERT INTO event_log(log_name, aggregate_id, seq_nr, payload) VALUES(?,?,?,?)",
  )
  // Expected next seq_nr for an aggregate. Events are always appended
  // contiguously from seq 0 (the OCC check below forbids gaps), so
  // `MAX(seq_nr)+1` equals the row count — but it reads the rightmost leaf of the
  // (log_name, aggregate_id, seq_nr) PK index in O(log n) instead of `COUNT(*)`
  // scanning every row for the aggregate. `COALESCE(…, -1)+1` yields 0 when empty.
  let nextSeqStmt = db->SqliteDriver.prepare(
    "SELECT COALESCE(MAX(seq_nr), -1) + 1 AS c FROM event_log WHERE log_name=? AND aggregate_id=?",
  )
  let selectByIdStmt = db->SqliteDriver.prepare(
    "SELECT payload FROM event_log WHERE log_name=? AND aggregate_id=? ORDER BY seq_nr ASC",
  )
  let lastRowidStmt = db->SqliteDriver.prepare("SELECT last_insert_rowid() AS r")

  let expectedNextSeq = (id: string): int =>
    switch nextSeqStmt->SqliteDriver.get([JSON.Encode.string(name), JSON.Encode.string(id)]) {
    | Some(row) =>
      switch row->Dict.get("c") {
      | Some(JSON.Number(n)) => Float.toInt(n)
      | _ => 0
      }
    | None => 0
    }

  // `track=false` for appendStream: bulk-replayed batches never flow through
  // the EventTopic publish cycle, so they must not enter the projection pending
  // set — an entry nobody resolves would pin the checkpoint low-watermark
  // forever (see ProjectionCheckpoint.res).
  let appendTracked = async (~track, seqNr, id, jsons: array<JSON.t>) => {
    try {
      let lastRowid = db->SqliteDriver.transaction(() => {
        let existing = expectedNextSeq(id)
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
        switch lastRowidStmt->SqliteDriver.get([]) {
        | Some(row) =>
          switch row->Dict.get("r") {
          | Some(JSON.Number(n)) => Float.toInt(n)
          | _ => 0
          }
        | None => 0
        }
      })
      // Register the committed batch as appended-but-not-yet-published for the
      // projection checkpoint low-watermark; Platform's afterPublish hook
      // resolves the msgIds once the publish cycle completes. A transaction's
      // inserts get contiguous rowids ending at lastRowid.
      if track && lastRowid > 0 {
        let count = jsons->Array.length
        ProjectionPending.trackAppended(
          ~axis=ProjectionPending.Aggregate,
          jsons
          ->Array.mapWithIndex((json, i) =>
            json
            ->JSON.Decode.object
            ->Option.flatMap(d => d->Dict.get("msgId"))
            ->Option.flatMap(JSON.Decode.string)
            ->Option.map(msgId => (msgId, lastRowid - count + 1 + i))
          )
          ->Array.filterMap(x => x),
        )
      }
      Ok()
    } catch {
    // The deliberate seq_nr check above throws Failure("conflict"); a lost race
    // shows up as a PRIMARY KEY violation on (log_name, aggregate_id, seq_nr) —
    // also a genuine OCC conflict. Every OTHER failure (disk full, SQL error,
    // locked db) is a real StorageFailure, not the retryable Conflict sentinel.
    | Failure(msg) =>
      msg == "conflict"
        ? Error(ReventlessCore.EventLog.Conflict)
        : Error(ReventlessCore.EventLog.StorageFailure(msg))
    | exn =>
      let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("")
      msg->String.includes("constraint failed")
        ? Error(ReventlessCore.EventLog.Conflict)
        : Error(ReventlessCore.EventLog.StorageFailure(msg == "" ? "storage error" : msg))
    }
  }

  let append: EventLog.append<string, JSON.t> = (seqNr, id, jsons) =>
    appendTracked(~track=true, seqNr, id, jsons)

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

  // Collect the stream and hand the whole batch to `append`, which inserts every
  // event under one transaction with a single OCC check (vs the old per-element
  // append: one transaction + one seq lookup per event over a bulk replay). This
  // also makes the replay atomic — all events land or none do, rather than
  // leaving a partial prefix committed if a later element hit a raced PK.
  let appendStream: EventLog.appendStream<string, JSON.t> = (startingSeqNr, id, stream) =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(jsons =>
      Effect.promise(() => appendTracked(~track=false, startingSeqNr, id, jsons))->Effect.flatMap(result =>
        switch result {
        | Ok() => Effect.succeed()
        // appendStream's error channel is a string; map the typed append error.
        | Error(ReventlessCore.EventLog.Conflict) => Effect.fail("conflict")
        | Error(StorageFailure(msg)) => Effect.fail(msg)
        }
      )
    )

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
