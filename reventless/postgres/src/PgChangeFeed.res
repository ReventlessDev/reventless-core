// DCB change feed — checkpointed polling with LISTEN/NOTIFY wakeup.
//
// This is the one component with no in-repo template (DynamoDB Streams has no
// drop-in equivalent). It is NOT logical decoding: events are already durably
// queryable in-table, so the feed is a fenced read over dcb_event plus a
// `dcb_subscription` checkpoint. `dcb_append` issues `pg_notify('dcb_<log>')`,
// which turns polling into near-real-time wakeup; a low-frequency fallback tick
// covers missed notifications (payload overflow, listener reconnect).
//
// The feed-consumer API below is a DOCUMENTED PUBLIC SURFACE of the package —
// external relays and platform packages bridging the feed onto a bus/topic are
// first-class consumers. Cursor semantics: the opaque `<xid8>:<position>` string
// (see DcbEventLogStorage_Postgres), which decodes to the (transaction_id,
// position) pair. Reads apply the xmin barrier, so a returned cursor is stable
// forever — an event committed late (lower position, later commit) is never
// skipped by a checkpointing reader.

open ReventlessCore
open Reventless

module Dcb = DcbEventLogStorage_Postgres

// One page of the feed. `events` are in (transaction_id, position) order;
// `cursor` is the checkpoint to persist and to pass as the next `after` (None
// when the page was empty — nothing new).
type batch = {
  events: array<DcbEventLog_Adapter.rawSequencedEvent>,
  cursor: option<DcbTag.sequencePosition>,
}

// Read up to `limit` events after `after` (the xmin-fenced feed query — no tag
// filter, whole log). Returns the events and the cursor of the last one.
let readBatch = async (
  pool: PgDriver.pool,
  ~logName: string,
  ~after: option<DcbTag.sequencePosition>=?,
  ~limit: int=500,
): batch => {
  let b = Dcb.mkBuilder()
  let where = Dcb.buildReadWhere(
    b,
    ~name=logName,
    ~query=[],
    ~after=after->Option.flatMap(Dcb.decodeCursor),
    ~applyFence=true,
  )
  let sql = `SELECT ${Dcb.selectColumns} FROM dcb_event WHERE ${where} ORDER BY transaction_id ASC, position ASC LIMIT ${Int.toString(limit)}`
  let rows = await pool->PgDriver.query(sql, b.params)
  let events = rows->Array.map(Dcb.rowToEvent)
  let cursor = switch events->Array.get(events->Array.length - 1) {
  | Some(last) => Some(last.position)
  | None => None
  }
  {events, cursor}
}

// --- Checkpoint contract (dcb_subscription) ---

// The persisted checkpoint for `subscriber`, encoded as a cursor, or None if the
// subscriber has never committed (→ replay from the beginning).
let loadCheckpoint = async (
  pool: PgDriver.pool,
  ~subscriber: string,
): option<DcbTag.sequencePosition> =>
  switch await pool->PgDriver.queryOne(
    "SELECT lpad(last_tx::text, 20, '0') || ':' || lpad(last_position::text, 20, '0') AS cursor
       FROM dcb_subscription WHERE subscriber = $1 AND last_position > 0",
    [JSON.Encode.string(subscriber)],
  ) {
  | Some(row) =>
    switch row->Dict.get("cursor") {
    | Some(JSON.String(s)) => Some(s)
    | _ => None
    }
  | None => None
  }

// Persist the checkpoint. Idempotent upsert; decodes the cursor to its two
// columns so a later `loadCheckpoint` round-trips exactly.
let saveCheckpoint = async (
  pool: PgDriver.pool,
  ~subscriber: string,
  ~cursor: DcbTag.sequencePosition,
): unit =>
  switch Dcb.decodeCursor(cursor) {
  | Some((tx, pos)) =>
    let _ = await pool->PgDriver.query(
      "INSERT INTO dcb_subscription(subscriber, last_tx, last_position)
       VALUES ($1, $2::xid8, $3::bigint)
       ON CONFLICT (subscriber)
       DO UPDATE SET last_tx = EXCLUDED.last_tx, last_position = EXCLUDED.last_position",
      [JSON.Encode.string(subscriber), JSON.Encode.string(tx), JSON.Encode.string(pos)],
    )
  | None => ()
  }

// --- Wakeup ---

// LISTEN on `dcb_<logName>`; `onWake` fires on every notification. Returns the
// dedicated client (caller owns it — release via PgDriver.unlisten). Pair with a
// low-frequency fallback tick in the consumer loop so a missed NOTIFY only adds
// latency, never a permanent stall.
let listen = (pool: PgDriver.pool, ~logName: string, ~onWake: unit => unit): promise<PgDriver.client> =>
  pool->PgDriver.listen(~channel="dcb_" ++ logName, ~onNotify=_ => onWake())

let unlisten = (client: PgDriver.client, ~logName: string): promise<unit> =>
  client->PgDriver.unlisten(~channel="dcb_" ++ logName)

// --- Reference consumer driver ---

// Drain the feed for `subscriber` from its checkpoint: repeatedly readBatch →
// `handle` the events → saveCheckpoint, until a short page. `handle` must be
// idempotent (a crash between handle and checkpoint replays the last batch).
// Returns the number of events processed. This is the in-repo reference consumer;
// a bus/topic relay would call the same primitives with its own `handle`.
let drain = async (
  pool: PgDriver.pool,
  ~logName: string,
  ~subscriber: string,
  ~limit: int=500,
  ~handle: array<DcbEventLog_Adapter.rawSequencedEvent> => promise<unit>,
): int => {
  let processed = ref(0)
  let cursor = ref(await loadCheckpoint(pool, ~subscriber))
  let continue = ref(true)
  while continue.contents {
    let {events, cursor: newCursor} = await readBatch(pool, ~logName, ~after=?cursor.contents, ~limit)
    if events->Array.length == 0 {
      continue := false
    } else {
      await handle(events)
      switch newCursor {
      | Some(c) =>
        await saveCheckpoint(pool, ~subscriber, ~cursor=c)
        cursor := Some(c)
      | None => ()
      }
      processed := processed.contents + events->Array.length
      if events->Array.length < limit {
        continue := false
      }
    }
  }
  processed.contents
}
