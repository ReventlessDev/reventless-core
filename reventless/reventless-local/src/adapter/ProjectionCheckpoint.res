// Projection checkpoints + startup catch-up for the SQLite backend (plan B5).
//
// Read models in the local platform are fed only by live bus events. Under the
// SQLite backend the event log and the QueryDb tables persist across restarts,
// but nothing recorded how far each read model's projection had gotten — a
// crash between an event-log append and the projection's QueryDb write silently
// diverged the read model from the log, permanently.
//
// Persisted state:
//   projection_checkpoint(read_model TEXT PRIMARY KEY, position INTEGER)
// where `position` is a global position over the shared `event_log` table —
// its SQLite rowid, monotonic because event_log rows are never deleted.
//
// Two mechanisms keep the checkpoint honest:
//
// 1. Runtime low-watermark. EventLogStorage_Sqlite tracks each appended batch
//    as pending (ProjectionPending, keyed by the stored events' unique
//    meta.msgId); Platform's afterPublish hook resolves the batch once
//    `Bus.publishEvent` has returned — LocalBus counts down every subscriber's
//    done_ before publishEvent resolves, so at that point all projections have
//    processed the events. The persisted watermark is `min(pending) - 1` (or
//    MAX(rowid) when nothing is pending), so an out-of-order publish completion
//    can never advance past a still-unpublished earlier append.
//
// 2. Startup catch-up. After the plugins are built, every handler in the Bus
//    projection catch-up registry is fed the stored events between its
//    checkpoint and the session's starting upper bound, in rowid order,
//    reconstructed into the same {id, meta, event} envelope live topic delivery
//    uses. Projection callbacks dispatch by meta.service and no-op on events
//    none of their mappings consume, so delivering the full missed range to
//    every projection is safe — redelivery inside the crash window is the same
//    at-least-once contract the deployed adapters already impose.
//
// Scope: aggregate EventLogs → ReadModel projections. DCB events (dcb_event)
// have their own position axis and feed StateViewSlice projections — their
// catch-up is a follow-up step of plan B5.

open ReventlessCore

type catchupHandler = (JSON.t, unit) => promise<unit>

let comp = "ProjectionCheckpoint"

let ensureSchema = (db: SqliteDriver.t) =>
  db->SqliteDriver.exec(
    "CREATE TABLE IF NOT EXISTS projection_checkpoint (read_model TEXT NOT NULL PRIMARY KEY, position INTEGER NOT NULL)",
  )

let intOf = (row: option<dict<JSON.t>>, key: string, ~default: int): int =>
  switch row->Option.flatMap(r => r->Dict.get(key)) {
  | Some(JSON.Number(n)) => Float.toInt(n)
  | _ => default
  }

// Highest event_log position on disk (0 when empty).
let maxPosition = (db: SqliteDriver.t): int => {
  EventLogStorage_Sqlite.ensureSchema(db)
  db
  ->SqliteDriver.prepare("SELECT COALESCE(MAX(rowid), 0) AS m FROM event_log")
  ->SqliteDriver.get([])
  ->intOf("m", ~default=0)
}

// Highest position provably fully projected: everything below the lowest
// pending append, or everything on disk when nothing is pending.
let currentWatermark = (db: SqliteDriver.t): int =>
  switch ProjectionPending.minPending() {
  | Some(lowest) => lowest - 1
  | None => maxPosition(db)
  }

let getPosition = (db: SqliteDriver.t, readModel: string): int => {
  ensureSchema(db)
  db
  ->SqliteDriver.prepare("SELECT position FROM projection_checkpoint WHERE read_model = ?")
  ->SqliteDriver.get([JSON.Encode.string(readModel)])
  ->intOf("position", ~default=0)
}

let setPosition = (db: SqliteDriver.t, readModel: string, position: int) => {
  ensureSchema(db)
  db
  ->SqliteDriver.prepare(
    "INSERT INTO projection_checkpoint(read_model, position) VALUES(?,?) ON CONFLICT(read_model) DO UPDATE SET position = excluded.position",
  )
  ->SqliteDriver.run([JSON.Encode.string(readModel), JSON.Encode.int(position)])
}

// Lift every checkpoint row that is behind the watermark. Never regresses a row.
let advanceAll = (db: SqliteDriver.t, watermark: int) => {
  ensureSchema(db)
  db
  ->SqliteDriver.prepare("UPDATE projection_checkpoint SET position = ? WHERE position < ?")
  ->SqliteDriver.run([JSON.Encode.int(watermark), JSON.Encode.int(watermark)])
}

// afterPublish hook body: the batch identified by these msgIds has completed
// its full publish/delivery cycle — resolve it and advance the checkpoints.
// No-op unless Platform enabled pending tracking (SQLite backend only).
let completePublished = (db: SqliteDriver.t, msgIds: array<string>) => {
  ProjectionPending.resolve(msgIds)
  advanceAll(db, currentWatermark(db))
}

// Rebuild the {id, meta, event} envelope live topic delivery uses
// (Message.encodeEvent' / composeEventJson') from a flat stored event —
// generically, without per-aggregate schemas: the flat shape carries the
// encoded id verbatim, the meta fields at top level, and the (event, data)
// split that combineMessage reverses. None on any malformed row.
let catchupEnvelope = (flat: JSON.t): option<JSON.t> =>
  switch flat->JSON.Decode.object {
  | None => None
  | Some(dict) =>
    switch (dict->Dict.get("id"), dict->Dict.get("event")) {
    | (Some(id), Some(JSON.String(eventType))) =>
      try {
        let data = switch dict->Dict.get("data") {
        | Some(JSON.Object(d)) => d
        | _ => Dict.make()
        }
        Some(
          Dict.fromArray([
            ("id", id),
            ("meta", Message.composeMeta(dict)),
            ("event", Message.combineMessage(eventType, data)),
          ])->JSON.Encode.object,
        )
      } catch {
      | _ => None
      }
    | _ => None
    }
  }

// Stored events in (afterPos, upTo], oldest first, as (position, flat payload).
let missedRows = (db: SqliteDriver.t, ~afterPos: int, ~upTo: int): array<(int, JSON.t)> =>
  db
  ->SqliteDriver.prepare(
    "SELECT rowid AS pos, payload FROM event_log WHERE rowid > ? AND rowid <= ? ORDER BY rowid ASC",
  )
  ->SqliteDriver.all([JSON.Encode.int(afterPos), JSON.Encode.int(upTo)])
  ->Array.filterMap(row =>
    switch (row->Dict.get("pos"), row->Dict.get("payload")) {
    | (Some(JSON.Number(pos)), Some(JSON.String(payload))) =>
      switch JSON.parseOrThrow(payload) {
      | json => Some((Float.toInt(pos), json))
      | exception _ => None
      }
    | _ => None
    }
  )

// Deliver each handler the stored events between its checkpoint and upperBound,
// then stamp every handler's checkpoint. upperBound is captured before the
// session appends anything, so this-session events (already live-delivered)
// are never redelivered; the final stamp uses the current watermark, which by
// then also covers this session's fully published appends.
let runCatchup = async (
  ~db: SqliteDriver.t,
  ~upperBound: int,
  ~handlers: array<(string, catchupHandler)>,
) => {
  ensureSchema(db)
  EventLogStorage_Sqlite.ensureSchema(db)
  for i in 0 to handlers->Array.length - 1 {
    let (name, handler) = handlers->Array.getUnsafe(i)
    let checkpoint = getPosition(db, name)
    if checkpoint < upperBound {
      let rows = missedRows(db, ~afterPos=checkpoint, ~upTo=upperBound)
      if rows->Array.length > 0 {
        EffectLogger.logInfo(
          ~comp,
          `catch-up: delivering ${rows->Array.length->Int.toString} missed event(s) (positions ${checkpoint->Int.toString}..${upperBound->Int.toString}] to ${name}`,
        )->Effect.runSync
      }
      for j in 0 to rows->Array.length - 1 {
        let (pos, flat) = rows->Array.getUnsafe(j)
        switch catchupEnvelope(flat) {
        | Some(envelope) =>
          switch await handler(envelope, ()) {
          | () => ()
          | exception _ =>
            EffectLogger.logWarn(
              ~comp,
              `catch-up: ${name} failed on stored event at position ${pos->Int.toString} — skipped`,
            )->Effect.runSync
          }
        | None =>
          EffectLogger.logWarn(
            ~comp,
            `catch-up: unreadable stored event at position ${pos->Int.toString} — skipped`,
          )->Effect.runSync
        }
      }
    }
  }
  // Everything up to the watermark is now projected for every handler: the
  // missed range was just applied, and anything past upperBound that completed
  // its publish cycle was live-delivered while this ran. Stamp unconditionally
  // — the row must EXIST (even at 0 on a fresh database) or the runtime
  // advanceAll, which only lifts existing rows, would leave the read model
  // checkpoint-less and the next startup would redeliver the whole history.
  let final = {
    let w = currentWatermark(db)
    w > upperBound ? w : upperBound
  }
  handlers->Array.forEach(((name, _)) => {
    let current = getPosition(db, name)
    setPosition(db, name, current > final ? current : final)
  })
}

// Platform entry point: waits one macrotask so the just-built plugins'
// Output.apply chains resolve and register their collector handlers (the same
// ~2-tick settling connectPlugin relies on), then snapshots the registry and
// catches up.
let startupCatchup = async (
  ~db: SqliteDriver.t,
  ~upperBound: int,
  ~handlers: unit => array<(string, catchupHandler)>,
) => {
  await Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), 0)
  })
  await runCatchup(~db, ~upperBound, ~handlers=handlers())
}
