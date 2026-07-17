// Projection checkpoints + startup catch-up for the SQLite backend (plan B5).
//
// Read models in the local platform are fed only by live bus events. Under the
// SQLite backend the event logs and the QueryDb tables persist across restarts,
// but nothing recorded how far each projection had gotten — a crash between an
// event append and the projection's QueryDb write silently diverged the read
// model from the log, permanently.
//
// Persisted state:
//   projection_checkpoint(read_model TEXT PRIMARY KEY, position INTEGER)
// One row per collector per position axis. Two independent axes exist, because
// the two persisted logs have unrelated global sequences (each axis uses its
// own table's rowid — monotonic, rows are never deleted):
//   Aggregate — event_log rowids, row key `<collector>`
//               (aggregate EventLogs → ReadModel projections)
//   Dcb       — dcb_event rowids, row key `dcb:<collector>`
//               (DCB slice events → StateViewSlice / stream projections)
//
// Two mechanisms keep the checkpoints honest:
//
// 1. Runtime low-watermark. The SQLite storage adapters track each appended
//    batch as pending (ProjectionPending, keyed by the events' unique
//    meta.msgId); Platform's afterPublish hook resolves the batch once
//    `Bus.publishEvent` has returned — LocalBus counts down every subscriber's
//    done_ before publishEvent resolves, so at that point all projections have
//    processed the events. The persisted watermark per axis is
//    `min(pending) - 1` (or MAX(rowid) when nothing is pending), so an
//    out-of-order publish completion can never advance past a still-unpublished
//    earlier append.
//
// 2. Startup catch-up. After the plugins are built, every handler in the Bus
//    projection catch-up registry is fed the stored events between its
//    checkpoint and the session's starting upper bound — per axis, in rowid
//    order — reconstructed into the same {id, meta, event} envelope live topic
//    delivery uses. Projection callbacks dispatch by meta.service and no-op on
//    events none of their mappings consume, so delivering both axes' missed
//    ranges to every projection is safe — redelivery inside the crash window is
//    the same at-least-once contract the deployed adapters already impose.
//
// DCB bulk seeds (Operations.appendStream — append without publish) share the
// storage append, so their pending entries are never resolved: within that
// session the DCB watermark conservatively stops advancing, and the next
// startup's catch-up delivers the seeded events to the projections —
// reconciling them with the log. (The aggregate axis instead skips tracking on
// its storage-level appendStream; its bulk path never publishes either way.)

open ReventlessCore

type catchupHandler = (JSON.t, unit) => promise<unit>

let comp = "ProjectionCheckpoint"

// Checkpoint row key: the DCB axis rows are namespaced with a `dcb:` prefix so
// one collector can hold an independent position on each axis.
let rowKey = (axis: ProjectionPending.axis, name: string) =>
  switch axis {
  | Aggregate => name
  | Dcb => "dcb:" ++ name
  }

let axisLabel = (axis: ProjectionPending.axis) =>
  switch axis {
  | Aggregate => "aggregate"
  | Dcb => "dcb"
  }

let ensureSchema = (db: SqliteDriver.t) =>
  db->SqliteDriver.exec(
    "CREATE TABLE IF NOT EXISTS projection_checkpoint (read_model TEXT NOT NULL PRIMARY KEY, position INTEGER NOT NULL)",
  )

let intOf = (row: option<dict<JSON.t>>, key: string, ~default: int): int =>
  switch row->Option.flatMap(r => r->Dict.get(key)) {
  | Some(JSON.Number(n)) => Float.toInt(n)
  | _ => default
  }

// Highest position on disk for the axis (0 when empty).
let maxPosition = (db: SqliteDriver.t, axis: ProjectionPending.axis): int =>
  switch axis {
  | Aggregate =>
    EventLogStorage_Sqlite.ensureSchema(db)
    db
    ->SqliteDriver.prepare("SELECT COALESCE(MAX(rowid), 0) AS m FROM event_log")
    ->SqliteDriver.get([])
    ->intOf("m", ~default=0)
  | Dcb =>
    DcbEventLogStorage_Sqlite.ensureSchema(db)
    db
    ->SqliteDriver.prepare("SELECT COALESCE(MAX(rowid), 0) AS m FROM dcb_event")
    ->SqliteDriver.get([])
    ->intOf("m", ~default=0)
  }

// Highest position provably fully projected on the axis: everything below the
// lowest pending append, or everything on disk when nothing is pending.
let currentWatermark = (db: SqliteDriver.t, axis: ProjectionPending.axis): int =>
  switch ProjectionPending.minPending(axis) {
  | Some(lowest) => lowest - 1
  | None => maxPosition(db, axis)
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

// Lift every checkpoint row of the axis that is behind the watermark. Never
// regresses a row. The `dcb:` prefix separates the two axes' rows.
let advanceAll = (db: SqliteDriver.t, axis: ProjectionPending.axis, watermark: int) => {
  ensureSchema(db)
  let axisFilter = switch axis {
  | Aggregate => "read_model NOT LIKE 'dcb:%'"
  | Dcb => "read_model LIKE 'dcb:%'"
  }
  db
  ->SqliteDriver.prepare(
    `UPDATE projection_checkpoint SET position = ? WHERE position < ? AND ${axisFilter}`,
  )
  ->SqliteDriver.run([JSON.Encode.int(watermark), JSON.Encode.int(watermark)])
}

// afterPublish hook body: the batch identified by these msgIds has completed
// its full publish/delivery cycle — resolve it and advance both axes'
// checkpoints to their current watermarks.
let completePublished = (db: SqliteDriver.t, msgIds: array<string>) => {
  ProjectionPending.resolve(msgIds)
  advanceAll(db, ProjectionPending.Aggregate, currentWatermark(db, ProjectionPending.Aggregate))
  advanceAll(db, ProjectionPending.Dcb, currentWatermark(db, ProjectionPending.Dcb))
}

// Rebuild the {id, meta, event} envelope live topic delivery uses
// (Message.encodeEvent' / composeEventJson') from a flat stored aggregate
// event — generically, without per-aggregate schemas: the flat shape carries
// the encoded id verbatim, the meta fields at top level, and the (event, data)
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

// Rebuild the published envelope for a DCB event row. Mirrors
// DcbEventLog_Operations.publishToEventTopic: id = the event's FIRST tag value
// (falling back to the log name), meta = the stored meta column, event =
// combineMessage(event_type, data).
let dcbCatchupEnvelope = (
  ~logName: string,
  ~eventType: string,
  ~dataText: string,
  ~metaText: string,
  ~firstTagValue: option<string>,
): option<JSON.t> =>
  switch (JSON.parseOrThrow(dataText), JSON.parseOrThrow(metaText)) {
  | (data, meta) =>
    let dataDict = data->JSON.Decode.object->Option.getOr(Dict.make())
    let entityId = firstTagValue->Option.getOr(logName)
    Some(
      Dict.fromArray([
        ("id", JSON.Encode.string(entityId)),
        ("meta", meta),
        ("event", Message.combineMessage(eventType, dataDict)),
      ])->JSON.Encode.object,
    )
  | exception _ => None
  }

// Stored events in (afterPos, upTo] on the axis, oldest first, as
// (position, envelope option) — None marks an unreadable row.
let missedRows = (
  db: SqliteDriver.t,
  axis: ProjectionPending.axis,
  ~afterPos: int,
  ~upTo: int,
): array<(int, option<JSON.t>)> =>
  switch axis {
  | Aggregate =>
    db
    ->SqliteDriver.prepare(
      "SELECT rowid AS pos, payload FROM event_log WHERE rowid > ? AND rowid <= ? ORDER BY rowid ASC",
    )
    ->SqliteDriver.all([JSON.Encode.int(afterPos), JSON.Encode.int(upTo)])
    ->Array.filterMap(row =>
      switch (row->Dict.get("pos"), row->Dict.get("payload")) {
      | (Some(JSON.Number(pos)), Some(JSON.String(payload))) =>
        switch JSON.parseOrThrow(payload) {
        | json => Some((Float.toInt(pos), catchupEnvelope(json)))
        | exception _ => Some((Float.toInt(pos), None))
        }
      | _ => None
      }
    )
  | Dcb =>
    // The first-tag subquery reproduces publish-time entityId derivation:
    // dcb_tag rows are inserted in tag order, so MIN(rowid) is the first tag.
    db
    ->SqliteDriver.prepare(
      "SELECT rowid AS pos, log_name, event_type, data, meta, (SELECT t.tag_value FROM dcb_tag t WHERE t.log_name = dcb_event.log_name AND t.position = dcb_event.position ORDER BY t.rowid ASC LIMIT 1) AS first_tag FROM dcb_event WHERE rowid > ? AND rowid <= ? ORDER BY rowid ASC",
    )
    ->SqliteDriver.all([JSON.Encode.int(afterPos), JSON.Encode.int(upTo)])
    ->Array.filterMap(row =>
      switch (
        row->Dict.get("pos"),
        row->Dict.get("log_name"),
        row->Dict.get("event_type"),
        row->Dict.get("data"),
        row->Dict.get("meta"),
      ) {
      | (
          Some(JSON.Number(pos)),
          Some(JSON.String(logName)),
          Some(JSON.String(eventType)),
          Some(JSON.String(dataText)),
          Some(JSON.String(metaText)),
        ) =>
        let firstTagValue = switch row->Dict.get("first_tag") {
        | Some(JSON.String(v)) => Some(v)
        | _ => None
        }
        Some((
          Float.toInt(pos),
          dcbCatchupEnvelope(~logName, ~eventType, ~dataText, ~metaText, ~firstTagValue),
        ))
      | _ => None
      }
    )
  }

// Deliver each handler the stored events between its checkpoint and the axis
// upper bound, on both axes, then stamp every handler's rows. The bounds are
// captured before the session appends anything, so this-session events
// (already live-delivered) are never redelivered; the final stamp uses the
// axis watermark, which by then also covers this session's fully published
// appends. Stamping is unconditional — the rows must EXIST (even at 0 on a
// fresh database) or the runtime advanceAll, which only lifts existing rows,
// would leave the read model checkpoint-less and the next startup would
// redeliver the whole history.
let runCatchup = async (
  ~db: SqliteDriver.t,
  ~upperBound: int,
  ~dcbUpperBound: int,
  ~handlers: array<(string, catchupHandler)>,
) => {
  ensureSchema(db)
  EventLogStorage_Sqlite.ensureSchema(db)
  DcbEventLogStorage_Sqlite.ensureSchema(db)
  let axes = [(ProjectionPending.Aggregate, upperBound), (ProjectionPending.Dcb, dcbUpperBound)]
  for i in 0 to handlers->Array.length - 1 {
    let (name, handler) = handlers->Array.getUnsafe(i)
    for a in 0 to axes->Array.length - 1 {
      let (axis, bound) = axes->Array.getUnsafe(a)
      let key = rowKey(axis, name)
      let checkpoint = getPosition(db, key)
      if checkpoint < bound {
        let rows = missedRows(db, axis, ~afterPos=checkpoint, ~upTo=bound)
        if rows->Array.length > 0 {
          EffectLogger.logInfo(
            ~comp,
            `catch-up: delivering ${rows
              ->Array.length
              ->Int.toString} missed ${axisLabel(
                axis,
              )} event(s) (positions ${checkpoint->Int.toString}..${bound->Int.toString}] to ${name}`,
          )->Effect.runSync
        }
        for j in 0 to rows->Array.length - 1 {
          let (pos, envelope) = rows->Array.getUnsafe(j)
          switch envelope {
          | Some(envelope) =>
            switch await handler(envelope, ()) {
            | () => ()
            | exception _ =>
              EffectLogger.logWarn(
                ~comp,
                `catch-up: ${name} failed on stored ${axisLabel(
                    axis,
                  )} event at position ${pos->Int.toString} — skipped`,
              )->Effect.runSync
            }
          | None =>
            EffectLogger.logWarn(
              ~comp,
              `catch-up: unreadable stored ${axisLabel(
                  axis,
                )} event at position ${pos->Int.toString} — skipped`,
            )->Effect.runSync
          }
        }
      }
    }
  }
  axes->Array.forEach(((axis, bound)) => {
    let final = {
      let w = currentWatermark(db, axis)
      w > bound ? w : bound
    }
    handlers->Array.forEach(((name, _)) => {
      let key = rowKey(axis, name)
      let current = getPosition(db, key)
      setPosition(db, key, current > final ? current : final)
    })
  })
}

// Platform entry point: waits one macrotask so the just-built plugins'
// Output.apply chains resolve and register their collector handlers (the same
// ~2-tick settling connectPlugin relies on), then snapshots the registry and
// catches up.
let startupCatchup = async (
  ~db: SqliteDriver.t,
  ~upperBound: int,
  ~dcbUpperBound: int,
  ~handlers: unit => array<(string, catchupHandler)>,
) => {
  await Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), 0)
  })
  await runCatchup(~db, ~upperBound, ~dcbUpperBound, ~handlers=handlers())
}
