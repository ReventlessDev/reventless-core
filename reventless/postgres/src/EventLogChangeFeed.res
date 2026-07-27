// Classic `event_log` change feed (B2.5) — the aggregate-path analogue of
// `PgChangeFeed` (which serves the DCB `dcb_event` log).
//
// Like the DCB feed this is NOT logical decoding: classic events are already
// durably queryable in-table, so the feed is an xmin-fenced read over `event_log`
// plus an `event_log_subscription` checkpoint. A statement-level AFTER INSERT
// trigger (`event_log_notify`, see PgSchema) issues `pg_notify('evlog_<log>')`,
// turning polling into near-real-time wakeup; a low-frequency fallback tick in the
// consumer covers missed notifications.
//
// Cursor semantics mirror the DCB feed exactly: the opaque `<xid8>:<global_seq>`
// string (zero-padded so string order == numeric order). Reads apply the xmin
// barrier (`transaction_id < pg_snapshot_xmin(pg_current_snapshot())`), so a
// returned cursor is stable forever — an event committed late (lower global_seq,
// later commit) is never skipped by a checkpointing reader. `global_seq` alone,
// being an IDENTITY assigned at INSERT, could NOT provide that guarantee.

// Reuse the shared `<a>:<b>` cursor codec from the DCB storage — identical
// format. Point at the runtime-pure `_Ops` module (no `@pulumi/pulumi`): this
// feed is drained by the deployed change-feed relay Lambda, whose cold-start
// graph must stay Pulumi-free.
module Dcb = DcbEventLogStorage_Postgres_Ops

// One classic event as the feed surfaces it. `payload` is the stored event JSON
// verbatim; a bus/topic relay transforms it into its target shape (e.g. the AWS
// EventCollector `{id, meta, event}` body) — that transform is not this package's
// concern.
type classicEvent = {
  cursor: string,
  aggregateId: string,
  seqNr: int,
  payload: JSON.t,
  msgId: option<string>,
}

// One page of the feed. `events` are in (transaction_id, global_seq) order;
// `cursor` is the checkpoint to persist and to pass as the next `after` (None when
// the page was empty — nothing new).
type batch = {
  events: array<classicEvent>,
  cursor: option<string>,
}

let selectColumns = "
  lpad(transaction_id::text, 20, '0') || ':' || lpad(global_seq::text, 20, '0') AS cursor,
  aggregate_id,
  seq_nr,
  payload,
  msg_id
"

let coerceInt = (v: JSON.t): int =>
  switch v {
  | JSON.Number(n) => Float.toInt(n)
  | JSON.String(s) => s->Int.fromString->Option.getOr(0)
  | _ => 0
  }

let rowToEvent = (row: dict<JSON.t>): classicEvent => {
  let str = key =>
    switch row->Dict.get(key) {
    | Some(JSON.String(s)) => s
    | _ => ""
    }
  {
    cursor: str("cursor"),
    aggregateId: str("aggregate_id"),
    seqNr: row->Dict.get("seq_nr")->Option.map(coerceInt)->Option.getOr(0),
    payload: row->Dict.get("payload")->Option.getOr(JSON.Encode.null),
    msgId: switch row->Dict.get("msg_id") {
    | Some(JSON.String(s)) => Some(s)
    | _ => None
    },
  }
}

// Read up to `limit` events after `after` (the xmin-fenced feed query — whole log).
// Returns the events and the cursor of the last one.
let readBatch = async (
  pool: PgDriver.pool,
  ~logName: string,
  ~after: option<string>=?,
  ~limit: int=500,
): batch => {
  let params = [JSON.Encode.string(logName)]
  let where = ref("log_name = $1 AND transaction_id < pg_snapshot_xmin(pg_current_snapshot())")
  switch after->Option.flatMap(Dcb.decodeCursor) {
  | Some((tx, pos)) =>
    // $2 = tx (referenced twice), $3 = global_seq.
    params->Array.push(JSON.Encode.string(tx))
    params->Array.push(JSON.Encode.string(pos))
    where :=
      where.contents ++
      " AND (transaction_id > $2::xid8 OR (transaction_id = $2::xid8 AND global_seq > $3::bigint))"
  | None => ()
  }
  let sql = `SELECT ${selectColumns} FROM event_log WHERE ${where.contents} ORDER BY transaction_id ASC, global_seq ASC LIMIT ${Int.toString(limit)}`
  let rows = await pool->PgDriver.query(sql, params)
  let events = rows->Array.map(rowToEvent)
  let cursor = switch events->Array.get(events->Array.length - 1) {
  | Some(last) => Some(last.cursor)
  | None => None
  }
  {events, cursor}
}

// --- Checkpoint contract (event_log_subscription) ---

// The persisted checkpoint for `subscriber`, encoded as a cursor, or None if the
// subscriber has never committed (→ replay from the beginning).
let loadCheckpoint = async (pool: PgDriver.pool, ~subscriber: string): option<string> =>
  switch await pool->PgDriver.queryOne(
    "SELECT lpad(last_tx::text, 20, '0') || ':' || lpad(last_global_seq::text, 20, '0') AS cursor
       FROM event_log_subscription WHERE subscriber = $1 AND last_global_seq > 0",
    [JSON.Encode.string(subscriber)],
  ) {
  | Some(row) =>
    switch row->Dict.get("cursor") {
    | Some(JSON.String(s)) => Some(s)
    | _ => None
    }
  | None => None
  }

// Persist the checkpoint. Idempotent upsert; decodes the cursor to its two columns
// so a later `loadCheckpoint` round-trips exactly.
let saveCheckpoint = async (pool: PgDriver.pool, ~subscriber: string, ~cursor: string): unit =>
  switch Dcb.decodeCursor(cursor) {
  | Some((tx, pos)) =>
    let _ = await pool->PgDriver.query(
      "INSERT INTO event_log_subscription(subscriber, last_tx, last_global_seq)
       VALUES ($1, $2::xid8, $3::bigint)
       ON CONFLICT (subscriber)
       DO UPDATE SET last_tx = EXCLUDED.last_tx, last_global_seq = EXCLUDED.last_global_seq",
      [JSON.Encode.string(subscriber), JSON.Encode.string(tx), JSON.Encode.string(pos)],
    )
  | None => ()
  }

// --- Wakeup ---

// LISTEN on `evlog_<logName>`; `onWake` fires on every notification. Returns the
// dedicated client (caller owns it — release via unlisten). Pair with a
// low-frequency fallback tick so a missed NOTIFY only adds latency, never a stall.
let listen = (pool: PgDriver.pool, ~logName: string, ~onWake: unit => unit): promise<
  PgDriver.client,
> => pool->PgDriver.listen(~channel="evlog_" ++ logName, ~onNotify=_ => onWake())

let unlisten = (client: PgDriver.client, ~logName: string): promise<unit> =>
  client->PgDriver.unlisten(~channel="evlog_" ++ logName)

// --- Reference consumer driver ---

// Drain the feed for `subscriber` from its checkpoint: repeatedly readBatch →
// `handle` the events → saveCheckpoint, until a short page. `handle` must be
// idempotent (a crash between handle and checkpoint replays the last batch).
// Returns the number of events processed.
let drain = async (
  pool: PgDriver.pool,
  ~logName: string,
  ~subscriber: string,
  ~limit: int=500,
  ~handle: array<classicEvent> => promise<unit>,
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
