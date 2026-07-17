// Runtime-pure DCB event-log operations for the Postgres backend.
//
// Holds everything the DEPLOYED Lambda runtime needs and imports NO
// `@pulumi/pulumi` (deploy-time only). The deployed DCB command entry point pulls
// these ops in unconditionally at cold start, so a deploy-time dependency here
// would leak into the Lambda import graph and fail resolution on real Lambda. The
// thin `DcbEventLogStorage_Postgres` wrapper `include`s this and adds the
// deploy-time `Pulumi.Output`-shaped adapter for local/deploy consumers.
// See docs/plans/deployed-lambda-esm-self-containment.md (Rung-3 finding).

open ReventlessCore
open Reventless

// Lock strategy for concurrent appends (B4). Advisory (default) is safe under
// PgBouncer transaction mode; RowLocks avoids advisory-lock connection pinning
// on RDS Proxy at the cost of a companion `dcb_scope` table.
type lockStrategy = [#AdvisoryLocks | #RowLocks]
let strategyParam = s =>
  switch s {
  | #AdvisoryLocks => "advisory"
  | #RowLocks => "rows"
  }

// Injected by reventless-local to feed the projection-checkpoint low-watermark
// (ProjectionPending, Dcb axis). Standalone/deploy use passes nothing.
type onAppended = array<(string, int)> => unit
let noTracking: onAppended = _ => ()

// SELECT list shared by read and readStream. `data`/`meta` are jsonb (returned
// already parsed); `tags` is text[] (a JS array); the cursor and recorded_at are
// computed in SQL so the row maps straight to a rawSequencedEvent.
let selectColumns = "
  lpad(transaction_id::text, 20, '0') || ':' || lpad(position::text, 20, '0') AS cursor,
  event_type,
  tags,
  data,
  meta,
  to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS recorded_at
"

// Decode a 'key=value' tag string (split on the first '=') back to a DcbTag.tag.
let decodeTag = (s: string): DcbTag.tag =>
  switch s->String.indexOf("=") {
  | -1 => {key: s, value: ""}
  | i => {
      key: s->String.slice(~start=0, ~end=i),
      value: s->String.slice(~start=i + 1, ~end=s->String.length),
    }
  }

let decodeTags = (v: option<JSON.t>): array<DcbTag.tag> =>
  switch v {
  | Some(JSON.Array(arr)) =>
    arr->Array.filterMap(x =>
      switch x {
      | JSON.String(s) => Some(decodeTag(s))
      | _ => None
      }
    )
  | _ => []
  }

let rowToEvent = (row: dict<JSON.t>): DcbEventLog_Adapter.rawSequencedEvent => {
  let str = key =>
    switch row->Dict.get(key) {
    | Some(JSON.String(s)) => s
    | _ => ""
    }
  let meta = switch row->Dict.get("meta") {
  | Some(metaJson) => metaJson->S.parseJsonOrThrow(Reventless.Message.metaSchema)
  | None => JsError.throwWithMessage("missing meta column in dcb_event row")
  }
  {
    DcbEventLog_Adapter.position: str("cursor"),
    eventType: str("event_type"),
    data: row->Dict.get("data")->Option.getOr(JSON.Encode.null),
    tags: decodeTags(row->Dict.get("tags")),
    meta,
    recordedAt: str("recorded_at"),
  }
}

// A tiny positional-parameter builder. Postgres uses `$1, $2, …` (not `?`), so we
// accumulate params and mint tokens as we build the WHERE. A token may be reused
// (same `$N`) to reference one param twice — used for the `after` cursor columns.
type paramBuilder = {mutable params: array<JSON.t>}
let mkBuilder = () => {params: []}
let param = (b: paramBuilder, v: JSON.t): string => {
  b.params->Array.push(v)
  "$" ++ Int.toString(b.params->Array.length)
}

// Build the read WHERE + params for a query. `applyFence` gates the xmin read
// barrier (true for consumer reads, so cursors are stable). `after` is the
// decoded (tx, pos) cursor pair as numeric strings.
let buildReadWhere = (
  b: paramBuilder,
  ~name: string,
  ~query: DcbTag.query,
  ~after: option<(string, string)>,
  ~applyFence: bool,
): string => {
  let parts = [`log_name = ${b->param(JSON.Encode.string(name))}`]
  if applyFence {
    parts->Array.push("transaction_id < pg_snapshot_xmin(pg_current_snapshot())")
  }
  switch after {
  | Some((tx, pos)) =>
    let txP = b->param(JSON.Encode.string(tx))
    let posP = b->param(JSON.Encode.string(pos))
    parts->Array.push(
      `(transaction_id > ${txP}::xid8 OR (transaction_id = ${txP}::xid8 AND position > ${posP}::bigint))`,
    )
  | None => ()
  }

  if query->Array.length > 0 {
    let clauseSqls = query->Array.map(clause => {
      let clauseParts = []
      switch clause.eventTypes {
      | Some(types) if types->Array.length > 0 =>
        let ph = types->Array.map(t => b->param(JSON.Encode.string(t)))->Array.join(",")
        clauseParts->Array.push(`event_type IN (${ph})`)
      | _ => ()
      }
      switch clause.tags {
      | Some(tags) if tags->Array.length > 0 =>
        let arr =
          tags
          ->Array.map(t => b->param(JSON.Encode.string(t.key ++ "=" ++ t.value)))
          ->Array.join(",")
        clauseParts->Array.push(`tags @> ARRAY[${arr}]::text[]`)
      | _ => ()
      }
      clauseParts->Array.length == 0 ? "TRUE" : "(" ++ clauseParts->Array.join(" AND ") ++ ")"
    })
    parts->Array.push("(" ++ clauseSqls->Array.join(" OR ") ++ ")")
  }

  parts->Array.join(" AND ")
}

// Strip the zero-padding a cursor carries for string-sortability, leaving a
// plain decimal both `::xid8` and `::bigint` parse unambiguously ("0" if empty).
let stripZeros = (s: string): string => {
  let t = s->String.replaceRegExp(%re("/^0+/"), "")
  t == "" ? "0" : t
}

// Split a '<xid8>:<position>' cursor into its two numeric-string columns.
let decodeCursor = (pos: DcbTag.sequencePosition): option<(string, string)> =>
  switch pos->String.split(":") {
  | [tx, p] => Some((stripZeros(tx), stripZeros(p)))
  | _ => None
  }

// Rows-per-page for readStream keyset pagination.
let pageSize = 500

let isConflict = (exn: exn): bool => {
  let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("")
  msg->String.includes("dcb_conflict") ||
  msg->String.includes("duplicate key") ||
  msg->String.includes("23505")
}

let countAll = async (pool: PgDriver.pool): int =>
  switch await pool->PgDriver.queryOne("SELECT COUNT(*)::bigint AS c FROM dcb_event", []) {
  | Some(row) =>
    switch row->Dict.get("c") {
    | Some(JSON.String(s)) => s->Int.fromString->Option.getOr(0)
    | Some(JSON.Number(n)) => Float.toInt(n)
    | _ => 0
    }
  | None => 0
  }

// Builds the DCB runtime op set bound to `pool`. Returns `(name, ops)`; the
// deploy-time `DcbEventLog_Adapter` wrapper lives in `DcbEventLogStorage_Postgres`.
let makeOps = (
  ~pool: PgDriver.pool,
  ~name: string,
  ~indexes as _,
  ~partitionTag as _,
  ~crossPartitionTagKeys as _=?,
  ~opts as _,
  ~lockStrategy: lockStrategy=#AdvisoryLocks,
  ~onAppended=noTracking,
): (string, DcbEventLog_Adapter.operations) => {
  // Fenced head cursor: the highest (transaction_id, position) visible under the
  // xmin barrier. Stable across reads, so it is a safe consistency marker.
  let currentHead = async (): option<string> =>
    switch await pool->PgDriver.queryOne(
      "SELECT lpad(transaction_id::text, 20, '0') || ':' || lpad(position::text, 20, '0') AS head
         FROM dcb_event
        WHERE log_name = $1 AND transaction_id < pg_snapshot_xmin(pg_current_snapshot())
        ORDER BY transaction_id DESC, position DESC
        LIMIT 1",
      [JSON.Encode.string(name)],
    ) {
    | Some(row) =>
      switch row->Dict.get("head") {
      | Some(JSON.String(s)) => Some(s)
      | _ => None
      }
    | None => None
    }

  let runQuery = async (~query, ~after): array<DcbEventLog_Adapter.rawSequencedEvent> => {
    let b = mkBuilder()
    let where = buildReadWhere(b, ~name, ~query, ~after, ~applyFence=true)
    let sql = `SELECT ${selectColumns} FROM dcb_event WHERE ${where} ORDER BY transaction_id ASC, position ASC`
    (await pool->PgDriver.query(sql, b.params))->Array.map(rowToEvent)
  }

  let read = async (~query: DcbTag.query, ~after=?): DcbEventLog_Adapter.rawReadResult => {
    let afterCols = after->Option.flatMap(decodeCursor)
    let events = await runQuery(~query, ~after=afterCols)
    switch await currentHead() {
    | Some(head) => {DcbEventLog_Adapter.events, headPosition: head}
    | None => ({DcbEventLog_Adapter.events: events}: DcbEventLog_Adapter.rawReadResult)
    }
  }

  let append = async (
    newEvents: array<DcbEventLog_Adapter.rawStoredEvent>,
    ~condition=?,
  ): result<DcbTag.sequencePosition, ReventlessInfra.DcbEventLog.appendError> => {
    let eventsJson = JSON.Array(
      newEvents->Array.map(ev =>
        JSON.Object(
          Dict.fromArray([
            ("event_type", JSON.Encode.string(ev.eventType)),
            (
              "tags",
              JSON.Array(ev.tags->Array.map(t => JSON.Encode.string(t.key ++ "=" ++ t.value))),
            ),
            ("data", ev.data),
            ("meta", ev.meta->S.reverseConvertToJsonOrThrow(Reventless.Message.metaSchema)),
          ]),
        )
      ),
    )
    let conditionParam = switch condition {
    | Some(cond: DcbTag.appendCondition) =>
      let queryJson = JSON.Array(
        cond.query->Array.map(clause =>
          JSON.Object(
            Dict.fromArray([
              (
                "eventTypes",
                switch clause.eventTypes {
                | Some(types) => JSON.Array(types->Array.map(JSON.Encode.string))
                | None => JSON.Encode.null
                },
              ),
              (
                "tags",
                switch clause.tags {
                | Some(tags) =>
                  JSON.Array(tags->Array.map(t => JSON.Encode.string(t.key ++ "=" ++ t.value)))
                | None => JSON.Encode.null
                },
              ),
            ]),
          )
        ),
      )
      let fields = [("query", queryJson)]
      switch cond.after {
      | Some(a) => fields->Array.push(("after", JSON.Encode.string(a)))
      | None => ()
      }
      JSON.Encode.string(JSON.stringify(JSON.Object(Dict.fromArray(fields))))
    | None => JSON.Encode.null
    }

    try {
      let rows = await pool->PgDriver.query(
        "SELECT dcb_append($1, $2::jsonb, $3::jsonb, $4) AS pos",
        [
          JSON.Encode.string(name),
          JSON.Encode.string(JSON.stringify(eventsJson)),
          conditionParam,
          JSON.Encode.string(strategyParam(lockStrategy)),
        ],
      )
      switch rows->Array.get(0)->Option.flatMap(r => r->Dict.get("pos")) {
      | Some(JSON.String(cursor)) =>
        // Feed the projection checkpoint (Dcb axis): (msgId, numeric position).
        onAppended(
          newEvents->Array.filterMap(ev =>
            switch decodeCursor(cursor) {
            | Some((_, pos)) =>
              pos->Int.fromString->Option.map(p => (ev.meta.Reventless.Message.msgId, p))
            | None => None
            }
          ),
        )
        Ok(cursor)
      | _ => Error(ReventlessInfra.DcbEventLog.StorageFailure("dcb_append returned no position"))
      }
    } catch {
    | exn =>
      isConflict(exn)
        ? Error(ReventlessInfra.DcbEventLog.Conflict)
        : Error(
            ReventlessInfra.DcbEventLog.StorageFailure(
              exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("storage error"),
            ),
          )
    }
  }

  // ~strongConsistency is a genuine no-op here: every read applies the xmin
  // barrier, so it is always safely consistent (at the cost of a few ms lag).
  //
  // Keyset pagination on (transaction_id, position): one ordered SQL source, no
  // per-clause fan-out / k-way merge / dedup (the DynamoDB runtime's layers have
  // no Postgres counterpart). Each page reads strictly after the previous page's
  // last row; a short page ends the stream.
  let readStream = (~query: DcbTag.query, ~after=?, ~strongConsistency as _=?) =>
    Stream.paginateEffect(after->Option.flatMap(decodeCursor), cursor =>
      Effect.promise(() => {
        let b = mkBuilder()
        let where = buildReadWhere(b, ~name, ~query, ~after=cursor, ~applyFence=true)
        let sql = `SELECT ${selectColumns}, transaction_id::text AS tx_raw, position::text AS pos_raw FROM dcb_event WHERE ${where} ORDER BY transaction_id ASC, position ASC LIMIT ${Int.toString(pageSize)}`
        pool->PgDriver.query(sql, b.params)
      })->Effect.map(rows => {
        let events = rows->Array.map(rowToEvent)
        // Continue only on a full page; the next `after` is this page's last row.
        let next = if rows->Array.length < pageSize {
          None
        } else {
          switch rows->Array.get(rows->Array.length - 1) {
          | Some(lastRow) =>
            switch (lastRow->Dict.get("tx_raw"), lastRow->Dict.get("pos_raw")) {
            | (Some(JSON.String(tx)), Some(JSON.String(p))) => Some(Some((tx, p)))
            | _ => None
            }
          | None => None
          }
        }
        (events, next)
      })
    )

  let ops: DcbEventLog_Adapter.operations = {read, append, readStream}
  (name, ops)
}
