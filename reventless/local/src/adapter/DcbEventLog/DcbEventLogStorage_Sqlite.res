// SQLite-backed DCB event log storage.
//
// Schema:
//   dcb_event(log_name, position INTEGER PRIMARY KEY auto, event_type, data, PRIMARY KEY(log_name,position))
//   dcb_tag  (log_name, position, tag_key, tag_value) with index on (log_name, tag_key, tag_value, position)
//
// Append:
//   - opens a transaction
//   - if a `condition` was supplied, runs the equivalent of `read(condition.query, after=condition.after)`;
//     any returned event aborts the transaction with `Error("conflict: condition check failed")`
//   - inserts each event under a freshly-allocated `position`
//   - returns the last inserted `position` as a string
//
// Read:
//   - applies `after` filter via `position > ?`
//   - applies the OR-of-clauses `query` filter — clauses with both `eventTypes`
//     and `tags` are matched via a tag-join + IN list; tag-only and type-only
//     forms degrade to the simpler shape
//
// readStream is materialised eagerly via read for now; streaming via
// statement.iterate() would require a Stream.fromIteratorEffect that the
// current ReScript Stream module does not expose.

open ReventlessCore
open Reventless

let ensureSchema = (db: SqliteDriver.t) => {
  db->SqliteDriver.exec(
    "CREATE TABLE IF NOT EXISTS dcb_event (log_name TEXT NOT NULL, position INTEGER NOT NULL, event_type TEXT NOT NULL, data TEXT NOT NULL, meta TEXT NOT NULL, recorded_at TEXT NOT NULL, PRIMARY KEY (log_name, position))",
  )
  db->SqliteDriver.exec(
    "CREATE TABLE IF NOT EXISTS dcb_tag (log_name TEXT NOT NULL, position INTEGER NOT NULL, tag_key TEXT NOT NULL, tag_value TEXT NOT NULL)",
  )
  db->SqliteDriver.exec(
    "CREATE INDEX IF NOT EXISTS dcb_tag_by_kv ON dcb_tag(log_name, tag_key, tag_value, position)",
  )
  // Serves the per-position tag hydration (the `WHERE log_name = ? AND position
  // IN (...)` batch). The `_by_kv` index leads with tag_key/tag_value, so it
  // cannot answer a position lookup — without this the batch scanned dcb_tag.
  db->SqliteDriver.exec(
    "CREATE INDEX IF NOT EXISTS dcb_tag_by_pos ON dcb_tag(log_name, position)",
  )
}

let posToInt = (pos: string) => pos->Int.fromString->Option.getOr(0)

let parseDataPayload = (s: string): JSON.t =>
  switch JSON.parseOrThrow(s) {
  | json => json
  | exception _ => JSON.Encode.null
  }

// Total DCB events persisted in this table. Used at startup to seed the
// event-tap counter so the timeline numbering continues across restarts.
let countAll = (db: SqliteDriver.t): int => {
  ensureSchema(db)
  switch db->SqliteDriver.prepare("SELECT COUNT(*) AS c FROM dcb_event")->SqliteDriver.get([]) {
  | Some(row) =>
    switch row->Dict.get("c") {
    | Some(JSON.Number(n)) => Float.toInt(n)
    | _ => 0
    }
  | None => 0
  }
}

// Pull the integer position out of a row column that may be Number or String
// (node:sqlite returns INTEGER as either, depending on size).
let coercePosition = (v: JSON.t): int =>
  switch v {
  | JSON.Number(n) => Float.toInt(n)
  | JSON.String(s) => posToInt(s)
  | _ => 0
  }

// SQL string-literal escape — the queries below build event-type IN lists
// dynamically and our event types come from compile-time enums (no quotes).
// The escape is defensive belt-and-braces; never reached in practice.
let sqlEscape = (s: string) => s->String.replaceAll("'", "''")

// Build the WHERE clause and bound params for one query clause.
// Returns (whereSql, params) where whereSql includes a leading `(`/trailing `)`
// and uses `dcb_event` table aliases throughout.
let buildClauseSql = (
  ~logName: string,
  ~clause: DcbTag.queryItem,
  ~after: option<int>,
): (string, array<JSON.t>) => {
  let parts = ref(["log_name = ?"])
  let params = ref([JSON.Encode.string(logName)])

  switch after {
  | Some(p) =>
    parts := parts.contents->Array.concat(["position > ?"])
    params := params.contents->Array.concat([JSON.Encode.int(p)])
  | None => ()
  }

  switch clause.eventTypes {
  | Some(types) if types->Array.length > 0 =>
    let placeholders = types->Array.map(_ => "?")->Array.join(",")
    parts := parts.contents->Array.concat([`event_type IN (${placeholders})`])
    types->Array.forEach(t => params := params.contents->Array.concat([JSON.Encode.string(t)]))
  | _ => ()
  }

  switch clause.tags {
  | Some(tags) if tags->Array.length > 0 =>
    // For each tag, require an EXISTS subquery on dcb_tag.
    tags->Array.forEach(tag => {
      let sub = `EXISTS (SELECT 1 FROM dcb_tag t WHERE t.log_name = ? AND t.position = dcb_event.position AND t.tag_key = ? AND t.tag_value = ?)`
      parts := parts.contents->Array.concat([sub])
      params :=
        params.contents->Array.concat([
          JSON.Encode.string(logName),
          JSON.Encode.string(tag.key),
          JSON.Encode.string(tag.value),
        ])
    })
  | _ => ()
  }

  ("(" ++ parts.contents->Array.join(" AND ") ++ ")", params.contents)
}

// The WHERE expression (+ bound params) for a query — shared by the row-fetching
// read path and the LIMIT-1 existence check the append-condition uses, so both
// match the exact same rows.
let buildQueryWhere = (
  ~logName: string,
  ~query: DcbTag.query,
  ~after: option<int>,
): (string, array<JSON.t>) => {
  if query->Array.length == 0 {
    let baseWhere = switch after {
    | Some(_) => "log_name = ? AND position > ?"
    | None => "log_name = ?"
    }
    let baseParams = switch after {
    | Some(p) => [JSON.Encode.string(logName), JSON.Encode.int(p)]
    | None => [JSON.Encode.string(logName)]
    }
    let _ = sqlEscape
    (baseWhere, baseParams)
  } else {
    let clauses = query->Array.map(c => buildClauseSql(~logName, ~clause=c, ~after))
    let combinedWhere = clauses->Array.map(((sql, _)) => sql)->Array.join(" OR ")
    let combinedParams = clauses->Array.flatMap(((_, p)) => p)
    (combinedWhere, combinedParams)
  }
}

let buildQuerySql = (
  ~logName: string,
  ~query: DcbTag.query,
  ~after: option<int>,
): (string, array<JSON.t>) => {
  let (where, params) = buildQueryWhere(~logName, ~query, ~after)
  (
    `SELECT position, event_type, data, meta, recorded_at FROM dcb_event WHERE ${where} ORDER BY position ASC`,
    params,
  )
}

let makeStorage = (
  ~db: SqliteDriver.t,
  ~name: string,
  ~indexes as _,
  ~partitionTag as _,
  ~opts as _,
) => {
  ensureSchema(db)

  let insertEventStmt = db->SqliteDriver.prepare(
    "INSERT INTO dcb_event(log_name, position, event_type, data, meta, recorded_at) VALUES(?,?,?,?,?,?)",
  )
  let lastRowidStmt = db->SqliteDriver.prepare("SELECT last_insert_rowid() AS r")
  let insertTagStmt = db->SqliteDriver.prepare(
    "INSERT INTO dcb_tag(log_name, position, tag_key, tag_value) VALUES(?,?,?,?)",
  )
  let maxPositionStmt = db->SqliteDriver.prepare(
    "SELECT COALESCE(MAX(position), 0) AS m FROM dcb_event WHERE log_name = ?",
  )
  let headPositionStmt = db->SqliteDriver.prepare(
    "SELECT MAX(position) AS m FROM dcb_event WHERE log_name = ?",
  )

  // Prepared-statement cache keyed on SQL text. `runQuery`, the batched tag
  // hydration, and the conflict check all build SQL whose shape varies with the
  // clause/position count; preparing per call (the old `runQuery`) recompiled the
  // same handful of shapes on every read. node:sqlite statements are re-runnable
  // with fresh params, so one prepare per distinct shape suffices.
  let stmtCache: Dict.t<SqliteDriver.statement> = Dict.make()
  let preparedFor = (sql: string): SqliteDriver.statement =>
    switch stmtCache->Dict.get(sql) {
    | Some(s) => s
    | None =>
      let s = db->SqliteDriver.prepare(sql)
      stmtCache->Dict.set(sql, s)
      s
    }

  let currentMaxPosition = (): int =>
    switch maxPositionStmt->SqliteDriver.get([JSON.Encode.string(name)]) {
    | Some(row) =>
      switch row->Dict.get("m") {
      | Some(v) => coercePosition(v)
      | None => 0
      }
    | None => 0
    }

  // Hydrate tags for a batch of positions in ONE query, grouped by position, in
  // insertion order (`rowid`) within each position — the same order the old
  // per-position query returned. Replaces the N+1 `tagsForPosition` per event.
  let tagsForPositions = (positions: array<int>): Dict.t<array<DcbTag.tag>> => {
    let byPos: Dict.t<array<DcbTag.tag>> = Dict.make()
    if positions->Array.length > 0 {
      let placeholders = positions->Array.map(_ => "?")->Array.join(",")
      let sql = `SELECT position, tag_key, tag_value FROM dcb_tag WHERE log_name = ? AND position IN (${placeholders}) ORDER BY position ASC, rowid ASC`
      let params =
        [JSON.Encode.string(name)]->Array.concat(positions->Array.map(JSON.Encode.int))
      preparedFor(sql)
      ->SqliteDriver.all(params)
      ->Array.forEach(row => {
        let pos = switch row->Dict.get("position") {
        | Some(v) => coercePosition(v)
        | None => 0
        }
        let key = switch row->Dict.get("tag_key") {
        | Some(JSON.String(s)) => s
        | _ => ""
        }
        let value = switch row->Dict.get("tag_value") {
        | Some(JSON.String(s)) => s
        | _ => ""
        }
        let k = Int.toString(pos)
        let arr = switch byPos->Dict.get(k) {
        | Some(a) => a
        | None =>
          let a = []
          byPos->Dict.set(k, a)
          a
        }
        arr->Array.push(({key, value}: DcbTag.tag))
      })
    }
    byPos
  }

  let runQuery = (~query: DcbTag.query, ~after: option<int>): array<DcbEventLog_Adapter.rawSequencedEvent> => {
    let (sql, params) = buildQuerySql(~logName=name, ~query, ~after)
    let rows = preparedFor(sql)->SqliteDriver.all(params)
    let positions = rows->Array.map(row =>
      switch row->Dict.get("position") {
      | Some(v) => coercePosition(v)
      | None => 0
      }
    )
    let tagsByPos = tagsForPositions(positions)
    rows->Array.map(row => {
      let position = switch row->Dict.get("position") {
      | Some(v) => coercePosition(v)
      | None => 0
      }
      let eventType = switch row->Dict.get("event_type") {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
      let data = switch row->Dict.get("data") {
      | Some(JSON.String(s)) => parseDataPayload(s)
      | _ => JSON.Encode.null
      }
      let meta = switch row->Dict.get("meta") {
      | Some(JSON.String(s)) =>
        switch JSON.parseOrThrow(s) {
        | metaJson => metaJson->Reventless.Util_Sury.fromJson(Reventless.Message.metaSchema)
        | exception _ => JsError.throwWithMessage("invalid meta JSON in dcb_event row")
        }
      | _ => JsError.throwWithMessage("missing meta column in dcb_event row")
      }
      let recordedAt = switch row->Dict.get("recorded_at") {
      | Some(JSON.String(s)) => s
      | _ => ""
      }
      ({
        DcbEventLog_Adapter.position: Int.toString(position),
        eventType,
        data,
        tags: tagsByPos->Dict.get(Int.toString(position))->Option.getOr([]),
        meta,
        recordedAt,
      }: DcbEventLog_Adapter.rawSequencedEvent)
    })
  }

  // Does any event match the query? The append-condition only needs existence,
  // so avoid materialising + tag-hydrating every conflicting row (the old
  // `runQuery(...)->Array.length > 0`): a `SELECT 1 … LIMIT 1` short-circuits.
  let anyMatch = (~query: DcbTag.query, ~after: option<int>): bool => {
    let (where, params) = buildQueryWhere(~logName=name, ~query, ~after)
    preparedFor(`SELECT 1 FROM dcb_event WHERE ${where} LIMIT 1`)
    ->SqliteDriver.get(params)
    ->Option.isSome
  }

  let read = async (
    ~query: DcbTag.query,
    ~after=?,
  ): DcbEventLog_Adapter.rawReadResult => {
    let afterInt = after->Option.map(posToInt)
    let events = runQuery(~query, ~after=afterInt)
    let head = currentMaxPosition()
    if head > 0 {
      {DcbEventLog_Adapter.events, headPosition: Int.toString(head)}
    } else {
      ({DcbEventLog_Adapter.events: events}: DcbEventLog_Adapter.rawReadResult)
    }
  }

  let append = async (
    newEvents: array<DcbEventLog_Adapter.rawStoredEvent>,
    ~condition=?,
  ): result<DcbTag.sequencePosition, ReventlessInfra.DcbEventLog.appendError> => {
    let result = ref(Ok(""))
    // (msgId, dcb_event rowid) per inserted event, for the projection
    // checkpoint's DCB-axis pending set. The rowid is read immediately after
    // each event insert — before the tag inserts move last_insert_rowid() to
    // the dcb_tag table. Registered only after the transaction commits.
    let appended: array<(string, int)> = []
    try {
      db->SqliteDriver.transaction(() => {
        switch condition {
        | Some(cond: DcbTag.appendCondition) =>
          let afterInt = cond.after->Option.map(posToInt)
          if anyMatch(~query=cond.query, ~after=afterInt) {
            throw(Failure("conflict: condition check failed"))
          }
        | None => ()
        }

        let mutable_ = ref(currentMaxPosition())
        let lastPos = ref(mutable_.contents)
        newEvents->Array.forEach(event => {
          mutable_ := mutable_.contents + 1
          let pos = mutable_.contents
          let metaJson = event.meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema)
          let recordedAt = ReventlessCore.Message.nowAsISOString()
          insertEventStmt->SqliteDriver.run([
            JSON.Encode.string(name),
            JSON.Encode.int(pos),
            JSON.Encode.string(event.eventType),
            JSON.Encode.string(JSON.stringify(event.data)),
            JSON.Encode.string(JSON.stringify(metaJson)),
            JSON.Encode.string(recordedAt),
          ])
          switch lastRowidStmt->SqliteDriver.get([]) {
          | Some(row) =>
            switch row->Dict.get("r") {
            | Some(JSON.Number(n)) => appended->Array.push((event.meta.msgId, Float.toInt(n)))
            | _ => ()
            }
          | None => ()
          }
          event.tags->Array.forEach(tag => {
            insertTagStmt->SqliteDriver.run([
              JSON.Encode.string(name),
              JSON.Encode.int(pos),
              JSON.Encode.string(tag.key),
              JSON.Encode.string(tag.value),
            ])
          })
          lastPos := pos
        })

        result := Ok(Int.toString(lastPos.contents))
      })
      ProjectionPending.trackAppended(~axis=ProjectionPending.Dcb, appended)
      result.contents
    } catch {
    // The deliberate append-condition failure throws Failure("conflict: …").
    | Failure(msg) =>
      msg->String.includes("conflict")
        ? Error(ReventlessInfra.DcbEventLog.Conflict)
        : Error(StorageFailure(msg))
    | exn =>
      // A lost race on the computed position shows up here as a PRIMARY KEY /
      // UNIQUE violation — also a genuine conflict. Every other failure (disk
      // full, SQL error, locked db) is a real StorageFailure, not the retryable
      // Conflict sentinel that would be retried forever.
      let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("")
      msg->String.includes("constraint failed")
        ? Error(ReventlessInfra.DcbEventLog.Conflict)
        : Error(StorageFailure(msg == "" ? "storage error" : msg))
    }
  }

  let _ = headPositionStmt

  // ~strongConsistency is a DynamoDB read-replica concept; the SQLite backend is
  // always consistent, so it is accepted (interface parity) and ignored.
  let readStream = (~query: DcbTag.query, ~after=?, ~strongConsistency as _=?) =>
    Effect.promise(() => read(~query, ~after?))
    ->Effect.map(result => result.events)
    ->Stream.fromEffect
    ->Stream.flatMap(arr => Stream.fromIterable(arr))

  (
    name,
    read,
    {
      DcbEventLog_Adapter.resources: [],
      operations: Pulumi.Output.make({DcbEventLog_Adapter.read, append, readStream}),
    },
  )
}

// No `Make(Bus)` functor here on purpose — dispatch is centralised in
// LocalDcbEventLogStorage.Make so callers only ever wire one module.
