// Startup projection catch-up for the Postgres backend.
//
// Under Backend.Postgres the event logs (classic + DCB) persist durably, but read
// models run on the in-memory live-query arm (LocalQueryDbStorage — the sync
// LocalBus registrations can't consume async pg). So on every startup the
// in-memory read models begin EMPTY and must be rebuilt by replaying the durable
// event log through the projection handlers — read models are derived data, the
// log is the source of truth.
//
// Unlike the SQLite ProjectionCheckpoint, there is no persisted checkpoint here:
// in-memory read models always start at position 0, so the full history
// `(0, head]` is replayed once. The `head` bound is captured BEFORE the plugins
// build (and before this session's Connect dispatches / commands append), so this
// session's own events — which are live-delivered — are never redelivered.
//
// The {id, meta, event} envelopes are reconstructed by ProjectionCheckpoint's
// builders so they match live topic delivery byte-for-byte.

module Pg = ReventlessPostgres.PgDriver

// Head positions captured before the session appends anything.
type bounds = {aggBound: int, dcbBound: int}

let intCol = (row: dict<JSON.t>, key: string): int =>
  switch row->Dict.get(key) {
  | Some(JSON.Number(n)) => Float.toInt(n)
  | Some(JSON.String(s)) => s->Int.fromString->Option.getOr(0)
  | _ => 0
  }

// Snapshot the current head of each axis. Dispatched before plugin build so the
// bound excludes this session's live-delivered appends.
let captureBounds = async (pool: Pg.pool): bounds => {
  let agg = switch await pool->Pg.queryOne(
    "SELECT COALESCE(MAX(global_seq), 0)::bigint AS m FROM event_log",
    [],
  ) {
  | Some(row) => intCol(row, "m")
  | None => 0
  }
  let dcb = switch await pool->Pg.queryOne(
    "SELECT COALESCE(MAX(position), 0)::bigint AS m FROM dcb_event",
    [],
  ) {
  | Some(row) => intCol(row, "m")
  | None => 0
  }
  {aggBound: agg, dcbBound: dcb}
}

// First tag value of a DCB event's text[] `tags` column ('key=value' → value),
// reproducing publish-time entityId derivation (the first tag).
let firstTagValue = (row: dict<JSON.t>): option<string> =>
  switch row->Dict.get("tags") {
  | Some(JSON.Array(arr)) =>
    switch arr->Array.get(0) {
    | Some(JSON.String(kv)) =>
      switch kv->String.indexOf("=") {
      | -1 => Some(kv)
      | i => Some(kv->String.slice(~start=i + 1, ~end=kv->String.length))
      }
    | _ => None
    }
  | _ => None
  }

// Deliver `envelope` to every handler in registration order (handlers dispatch by
// meta.service and no-op on events none of their mappings consume, so delivering
// both axes to every projection is safe — same at-least-once contract the
// deployed adapters impose).
let deliver = async (
  handlers: array<(string, ProjectionCheckpoint.catchupHandler)>,
  envelope: JSON.t,
) =>
  for i in 0 to handlers->Array.length - 1 {
    let (_name, handler) = handlers->Array.getUnsafe(i)
    switch await handler(envelope, ()) {
    | () => ()
    | exception _ => ()
    }
  }

let runCatchup = async (
  ~pool: Pg.pool,
  ~bounds: bounds,
  ~handlers: array<(string, ProjectionCheckpoint.catchupHandler)>,
) => {
  // --- Aggregate axis: flat stored events, global_seq order ---
  let aggRows = await pool->Pg.query(
    "SELECT payload FROM event_log WHERE global_seq <= $1::bigint ORDER BY global_seq ASC",
    [JSON.Encode.int(bounds.aggBound)],
  )
  for i in 0 to aggRows->Array.length - 1 {
    let row = aggRows->Array.getUnsafe(i)
    switch row->Dict.get("payload") {
    | Some(payload) =>
      switch ProjectionCheckpoint.catchupEnvelope(payload) {
      | Some(envelope) => await deliver(handlers, envelope)
      | None => ()
      }
    | None => ()
    }
  }

  // --- DCB axis: reconstruct the published envelope, position order ---
  let dcbRows = await pool->Pg.query(
    "SELECT log_name, event_type, data, meta, tags FROM dcb_event WHERE position <= $1::bigint ORDER BY position ASC",
    [JSON.Encode.int(bounds.dcbBound)],
  )
  for i in 0 to dcbRows->Array.length - 1 {
    let row = dcbRows->Array.getUnsafe(i)
    switch (
      row->Dict.get("log_name"),
      row->Dict.get("event_type"),
      row->Dict.get("data"),
      row->Dict.get("meta"),
    ) {
    | (Some(JSON.String(logName)), Some(JSON.String(eventType)), Some(data), Some(meta)) =>
      switch ProjectionCheckpoint.dcbCatchupEnvelope(
        ~logName,
        ~eventType,
        ~dataText=JSON.stringify(data),
        ~metaText=JSON.stringify(meta),
        ~firstTagValue=firstTagValue(row),
      ) {
      | Some(envelope) => await deliver(handlers, envelope)
      | None => ()
      }
    | _ => ()
    }
  }
}

// Platform entry point: waits one macrotask so the just-built plugins' Output.apply
// chains register their collector handlers (mirrors ProjectionCheckpoint.startupCatchup),
// then replays the captured history.
let startupCatchup = async (
  ~pool: Pg.pool,
  ~bounds: bounds,
  ~handlers: unit => array<(string, ProjectionCheckpoint.catchupHandler)>,
) => {
  await Promise.make((resolve, _) => {
    let _ = setTimeout(() => resolve(), 0)
  })
  await runCatchup(~pool, ~bounds, ~handlers=handlers())
}
