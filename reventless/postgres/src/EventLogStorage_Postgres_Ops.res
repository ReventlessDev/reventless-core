// Runtime-pure classic (OCC) event-log operations for the Postgres backend.
//
// This module holds everything the DEPLOYED Lambda runtime needs and imports NO
// `@pulumi/pulumi` — deploy-time-only. The deployed aggregate entry point pulls
// these ops in unconditionally at cold start, so any deploy-time dependency here
// leaks into the Lambda import graph and fails resolution (`@pulumi/pulumi` exists
// in no Lambda — not the layer, not `/var/runtime`). The thin
// `EventLogStorage_Postgres` wrapper adds the deploy-time `Pulumi.Output`-shaped
// adapter on top for local/deploy consumers; the runtime imports `makeOps` here.
// See docs/plans/deployed-lambda-esm-self-containment.md (Rung-3 finding).

open ReventlessCore

// Injected by reventless-local to feed the projection-checkpoint low-watermark
// (ProjectionPending, aggregate axis). Standalone/deploy use passes nothing.
type onAppended = array<(string, int)> => unit
let noTracking: onAppended = _ => ()

let decodePayload = (row: dict<JSON.t>): JSON.t =>
  row->Dict.get("payload")->Option.getOr(JSON.Encode.null)

let coerceInt = (v: JSON.t): int =>
  switch v {
  | JSON.Number(n) => Float.toInt(n)
  | JSON.String(s) => s->Int.fromString->Option.getOr(0)
  | _ => 0
  }

// Total events across all aggregates. Seeds the event-tap counter at startup so
// timeline numbering continues across restarts.
let countAll = async (pool: PgDriver.pool): int =>
  switch await pool->PgDriver.queryOne("SELECT COUNT(*)::bigint AS c FROM event_log", []) {
  | Some(row) => row->Dict.get("c")->Option.map(coerceInt)->Option.getOr(0)
  | None => 0
  }

let isUniqueViolation = (exn: exn): bool => {
  let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("")
  // pg surfaces the SQLSTATE on `.code`; the message also carries the constraint.
  msg->String.includes("duplicate key") ||
  msg->String.includes("unique") ||
  msg->String.includes("23505")
}

// Builds the classic runtime op set bound to `pool`. Returns `(name, ops)`; the
// deploy-time `EventLog_Adapter` wrapper lives in `EventLogStorage_Postgres`.
let makeOps = (
  ~pool: PgDriver.pool,
  ~name: string,
  ~opts as _,
  ~onAppended=noTracking,
): (string, EventLog_Adapter.operations) => {
  let appendTracked = async (~track, seqNr: int, id: string, jsons: array<JSON.t>) => {
    // Empty append is a legitimate no-op (at-least-once retries, idempotent
    // commands), NOT a conflict — return before the guarded insert whose 0-row
    // result would otherwise be read as a conflict.
    if jsons->Array.length == 0 {
      Ok()
    } else {
      try {
        let rows = await pool->PgDriver.query(
          "INSERT INTO event_log(log_name, aggregate_id, seq_nr, payload, msg_id)
           SELECT $1, $2, $3::bigint + (ord - 1), value, value->>'msgId'
             FROM jsonb_array_elements($4::jsonb) WITH ORDINALITY AS t(value, ord)
            WHERE $3::bigint = (SELECT COALESCE(MAX(seq_nr), -1) + 1
                                  FROM event_log
                                 WHERE log_name = $1 AND aggregate_id = $2)
           RETURNING global_seq, msg_id",
          [
            JSON.Encode.string(name),
            JSON.Encode.string(id),
            JSON.Encode.int(seqNr),
            JSON.Encode.string(JSON.stringify(JSON.Array(jsons))),
          ],
        )
        if rows->Array.length == 0 {
          // WHERE guard rejected the seq — a genuine OCC conflict (gap or stale).
          Error(EventLog.Conflict)
        } else {
          if track {
            onAppended(
              rows->Array.filterMap(row =>
                switch (row->Dict.get("msg_id"), row->Dict.get("global_seq")) {
                | (Some(JSON.String(msgId)), Some(gseq)) => Some((msgId, coerceInt(gseq)))
                | _ => None
                }
              ),
            )
          }
          Ok()
        }
      } catch {
      | exn =>
        isUniqueViolation(exn)
          ? Error(EventLog.Conflict)
          : Error(
              EventLog.StorageFailure(
                exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("storage error"),
              ),
            )
      }
    }
  }

  let append: EventLog.append<string, JSON.t> = (seqNr, id, jsons) =>
    appendTracked(~track=true, seqNr, id, jsons)

  let replayArray = async (id: string, ~fromSeq=0): array<JSON.t> =>
    (await pool->PgDriver.query(
      "SELECT payload FROM event_log
        WHERE log_name = $1 AND aggregate_id = $2 AND seq_nr >= $3::bigint
        ORDER BY seq_nr ASC",
      [JSON.Encode.string(name), JSON.Encode.string(id), JSON.Encode.int(fromSeq)],
    ))->Array.map(decodePayload)

  let replay: EventLog.replay<string, JSON.t> = id => replayArray(id)

  let replayStream = (id, ~fromSeq=?) =>
    Effect.promise(() => replayArray(id, ~fromSeq?))
    ->Stream.fromEffect
    ->Stream.flatMap(arr => Stream.fromIterable(arr))

  let latestSnapshot: EventLog.latestSnapshot<string> = async id =>
    switch await pool->PgDriver.queryOne(
      "SELECT seq_nr, state, schema_hash FROM snapshot WHERE log_name = $1 AND aggregate_id = $2",
      [JSON.Encode.string(name), JSON.Encode.string(id)],
    ) {
    | Some(row) =>
      switch (row->Dict.get("seq_nr"), row->Dict.get("state"), row->Dict.get("schema_hash")) {
      | (Some(seq), Some(state), Some(JSON.String(schemaHash))) =>
        Ok(Some({EventLog.seqNr: coerceInt(seq), state, schemaHash}))
      | _ => Error("snapshot row has unexpected shape")
      }
    | None => Ok(None)
    }

  let writeSnapshot: EventLog.writeSnapshot<string> = async (id, snap) =>
    try {
      let _ = await pool->PgDriver.query(
        "INSERT INTO snapshot(log_name, aggregate_id, seq_nr, state, schema_hash)
         VALUES ($1, $2, $3::bigint, $4::jsonb, $5)
         ON CONFLICT (log_name, aggregate_id)
         DO UPDATE SET seq_nr = EXCLUDED.seq_nr, state = EXCLUDED.state, schema_hash = EXCLUDED.schema_hash",
        [
          JSON.Encode.string(name),
          JSON.Encode.string(id),
          JSON.Encode.int(snap.EventLog.seqNr),
          JSON.Encode.string(JSON.stringify(snap.state)),
          JSON.Encode.string(snap.schemaHash),
        ],
      )
      Ok()
    } catch {
    | exn =>
      Error(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("snapshot write error"))
    }

  let appendStream: EventLog.appendStream<string, JSON.t> = (startingSeqNr, id, stream) =>
    stream
    ->Stream.runCollect
    ->Effect.flatMap(jsons =>
      Effect.promise(() => appendTracked(~track=false, startingSeqNr, id, jsons))->Effect.flatMap(result =>
        switch result {
        | Ok() => Effect.succeed()
        | Error(EventLog.Conflict) => Effect.fail("conflict")
        | Error(StorageFailure(msg)) => Effect.fail(msg)
        }
      )
    )

  let ops: EventLog_Adapter.operations = {
    append,
    replay,
    replayStream,
    appendStream,
    latestSnapshot,
    writeSnapshot,
  }
  (name, ops)
}
