// The Postgres backend's part in the read across every event log and in the
// tap's positions: its logs are read backwards by `global_seq` (aggregate) and
// `position` (DCB), and each appended event's position is noted for the tap.

module AggOps = ReventlessPostgres.EventLogStorage_Postgres_Ops
module DcbOps = ReventlessPostgres.DcbEventLogStorage_Postgres_Ops

/** For an aggregate log's `onAppended`: notes each event's `global_seq`. */
let noteAppended = (~name: string) =>
  (pairs: array<(string, int)>) =>
    pairs->Array.forEach(((msgId, position)) =>
      LocalEventLogRead.note(~log=name, ~msgId, ~position=position->Int.toFloat)
    )

let registerAggregate = (~pool: ReventlessPostgres.PgDriver.pool, ~name: string) =>
  LocalEventLogRead.register(~log=name, ~kind=Aggregate, async (~bound, ~limit, ~correlationId) =>
    (
      await AggOps.readBackwards(
        pool,
        ~name,
        ~bound=bound->Option.map(b =>
          switch b {
          | LocalEventLogRead.Below(p) => AggOps.Below(p)
          | AtMost(p) => AggOps.AtMost(p)
          }
        ),
        ~limit,
        ~correlationId,
      )
    )->Array.map(((position, entityId, payload)) =>
      LocalEventLogRead.storedOfFlat(~log=name, ~position, ~entityId, payload)
    )
  )

let registerDcb = (~pool: ReventlessPostgres.PgDriver.pool, ~name: string) =>
  LocalEventLogRead.register(~log=name, ~kind=Dcb, async (~bound, ~limit, ~correlationId) =>
    (
      await DcbOps.readBackwards(
        pool,
        ~name,
        ~bound=bound->Option.map(b =>
          switch b {
          | LocalEventLogRead.Below(p) => DcbOps.Below(p)
          | AtMost(p) => DcbOps.AtMost(p)
          }
        ),
        ~limit,
        ~correlationId,
      )
    )->Array.map(((position, e)): LocalEventLogRead.stored => {
      log: name,
      position,
      eventType: e.eventType,
      tags: e.tags,
      payload: e.data,
      meta: e.meta->Reventless.Util_Sury.toJson(Reventless.Message.metaSchema),
      recordedAt: e.recordedAt,
    })
  )

/** A DCB append that also notes where each event went. The append returns only
    its last cursor, so the positions are read back once. */
let notingDcbAppend = (
  ~pool: ReventlessPostgres.PgDriver.pool,
  ~name: string,
  append: (
    array<ReventlessCore.DcbEventLog_Adapter.rawStoredEvent>,
    ~condition: Reventless.DcbTag.appendCondition=?,
  ) => promise<result<Reventless.DcbTag.sequencePosition, ReventlessInfra.DcbEventLog.appendError>>,
) =>
  async (events, ~condition=?) => {
    let result = await append(events, ~condition?)
    switch result {
    | Ok(cursor) =>
      switch await DcbOps.positionsOfAppend(pool, ~name, ~cursor) {
      | positions =>
        positions->Array.forEach(((msgId, position)) =>
          LocalEventLogRead.note(~log=name, ~msgId, ~position)
        )
      | exception _ => ()
      }
    | Error(_) => ()
    }
    result
  }
