// Projection checkpoints + startup catch-up (plan B5).
//
// Simulates the crash window the checkpoint exists for: events persisted in the
// SQLite event_log whose projections never ran (no checkpoint advance). At the
// next startup runCatchup must redeliver exactly the missed range — in rowid
// order, reconstructed into the live {id, meta, event} envelope — and stamp the
// checkpoints so a second startup delivers nothing.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let makeFreshDb = () => SqliteDriver.openDb(~path=":memory:")

// A flat stored-event payload in the exact shape EventLog_Operations.encodeEvent'
// persists: envelope fields + the meta fields flattened to the top level.
let flatEvent = (~id, ~seq, ~eventType, ~data=[], ~msgId, ~service="Products") =>
  JSON.Encode.object(
    Dict.fromArray([
      ("id", JSON.Encode.string(id)),
      ("position", JSON.Encode.string(seq->Int.toString->String.padStart(9, "0"))),
      ("event", JSON.Encode.string(eventType)),
      ("data", JSON.Encode.object(Dict.fromArray(data))),
      ("recordedAt", JSON.Encode.string("2026-07-03T00:00:00.000Z")),
      ("service", JSON.Encode.string(service)),
      ("time", JSON.Encode.string("2026-07-03T00:00:00.000Z")),
      ("msgId", JSON.Encode.string(msgId)),
      ("correlationId", JSON.Encode.string(msgId)),
    ]),
  )

let msgIdOfEnvelope = (json: JSON.t) =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("meta"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(m => m->Dict.get("msgId"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("<none>")

// Recording catch-up handler.
let makeHandler = () => {
  let received: array<JSON.t> = []
  let handler = (json: JSON.t, _ctx: unit) => {
    received->Array.push(json)
    Promise.resolve()
  }
  (received, handler)
}

// A DCB raw stored event with a deterministic msgId.
let dcbEvent = (~eventType, ~tags, ~data=[], ~msgId): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
  eventType,
  data: JSON.Encode.object(Dict.fromArray(data)),
  tags,
  meta: {
    service: "OrderingDcbEventLog",
    time: "2026-07-03T00:00:00.000Z",
    msgId,
    correlationId: msgId,
  },
}

let makeDcbStorage = async (db, ~name) => {
  let (_, _, storage) = DcbEventLogStorage_Sqlite.makeStorage(
    ~db,
    ~name,
    ~indexes=[],
    ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
    ~opts,
  )
  await storage.operations->TestRunner.resolve
}

let idOfEnvelope = (json: JSON.t) =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("id"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("<none>")

describe("ProjectionCheckpoint", () => {
  describe("pending low-watermark", () => {
    testPromise(
      "out-of-order publish completion cannot advance past a pending earlier append",
      async () => {
        ProjectionPending.reset()
        ProjectionPending.enableTracking()
        module TestBus = LocalBus.Make()
        module DbProvider = {
          let db = makeFreshDb()
        }
        module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
        let s = Storage.make(~name="agg", ~owner=None, ~opts)
        let ops = await s.operations->TestRunner.resolve

        // Batch A (rowids 1-2) appended before batch B (rowid 3).
        let _ = await ops.append(
          0,
          "id-1",
          [
            flatEvent(~id="id-1", ~seq=0, ~eventType="Created", ~msgId="a1"),
            flatEvent(~id="id-1", ~seq=1, ~eventType="Renamed", ~msgId="a2"),
          ],
        )
        let _ = await ops.append(
          0,
          "id-2",
          [flatEvent(~id="id-2", ~seq=0, ~eventType="Created", ~msgId="b1")],
        )

        let db = DbProvider.db
        ProjectionCheckpoint.setPosition(db, "RM", 0)

        // B's publish completes first — the watermark must stay below A.
        ProjectionCheckpoint.completePublished(db, ["b1"])
        expect(ProjectionCheckpoint.getPosition(db, "RM"))->toBe(0)

        // A completes — nothing pending, watermark = MAX(rowid).
        ProjectionCheckpoint.completePublished(db, ["a1", "a2"])
        expect(ProjectionCheckpoint.getPosition(db, "RM"))->toBe(3)
        ProjectionPending.reset()
      },
    )

    testPromise("appendStream batches never enter the pending set", async () => {
      ProjectionPending.reset()
      ProjectionPending.enableTracking()
      module TestBus = LocalBus.Make()
      module DbProvider = {
        let db = makeFreshDb()
      }
      module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
      let s = Storage.make(~name="agg", ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve

      // Bulk replay path: no publish cycle will ever resolve these, so they
      // must not pin the low-watermark.
      let _ =
        await ops.appendStream(
          0,
          "id-bulk",
          Stream.fromIterable([
            flatEvent(~id="id-bulk", ~seq=0, ~eventType="Created", ~msgId="s1"),
            flatEvent(~id="id-bulk", ~seq=1, ~eventType="Renamed", ~msgId="s2"),
          ]),
        )->Effect.runPromise

      expect(ProjectionPending.minPending(ProjectionPending.Aggregate))->toEqual(None)

      // With nothing pending the watermark covers the bulk rows.
      let db = DbProvider.db
      ProjectionCheckpoint.setPosition(db, "RM", 0)
      ProjectionCheckpoint.completePublished(db, [])
      expect(ProjectionCheckpoint.getPosition(db, "RM"))->toBe(2)
      ProjectionPending.reset()
    })
  })

  describe("catchupEnvelope", () => {
    testSync("rebuilds the live {id, meta, event} envelope from a stored row", () => {
      let flat = flatEvent(
        ~id="p-1",
        ~seq=4,
        ~eventType="Created",
        ~data=[("name", JSON.Encode.string("Widget"))],
        ~msgId="m-1",
      )
      switch ProjectionCheckpoint.catchupEnvelope(flat) {
      | None => expect("envelope")->toBe("None")
      | Some(envelope) =>
        let dict = envelope->JSON.Decode.object->Option.getOrThrow
        expect(dict->Dict.get("id"))->toEqual(Some(JSON.Encode.string("p-1")))
        expect(msgIdOfEnvelope(envelope))->toBe("m-1")
        // Payload-bearing variant: TAG + payload fields (splitMessage reversed).
        expect(dict->Dict.get("event"))->toEqual(
          Some(
            JSON.Encode.object(
              Dict.fromArray([
                ("TAG", JSON.Encode.string("Created")),
                ("name", JSON.Encode.string("Widget")),
              ]),
            ),
          ),
        )
      }
    })

    testSync("payload-less variants come back as a bare JSON string", () => {
      let flat = flatEvent(~id="p-1", ~seq=0, ~eventType="Deleted", ~msgId="m-2")
      let event =
        ProjectionCheckpoint.catchupEnvelope(flat)
        ->Option.flatMap(JSON.Decode.object)
        ->Option.flatMap(d => d->Dict.get("event"))
      expect(event)->toEqual(Some(JSON.Encode.string("Deleted")))
    })

    testSync("malformed stored rows yield None instead of throwing", () => {
      // Missing the required meta fields (composeMeta would throw).
      let flat = JSON.Encode.object(
        Dict.fromArray([
          ("id", JSON.Encode.string("p-1")),
          ("event", JSON.Encode.string("Created")),
        ]),
      )
      expect(ProjectionCheckpoint.catchupEnvelope(flat))->toEqual(None)
      expect(ProjectionCheckpoint.catchupEnvelope(JSON.Encode.string("junk")))->toEqual(None)
    })
  })

  describe("runCatchup", () => {
    testPromise("delivers the missed range in rowid order, exactly once", async () => {
      ProjectionPending.reset()
      module TestBus = LocalBus.Make()
      module DbProvider = {
        let db = makeFreshDb()
      }
      module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
      let s = Storage.make(~name="agg", ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve
      let db = DbProvider.db

      // Interleaved appends across two aggregates — global order is rowid
      // order (m1, m2, m3), not per-aggregate grouping.
      let _ = await ops.append(0, "id-1", [flatEvent(~id="id-1", ~seq=0, ~eventType="Created", ~msgId="m1")])
      let _ = await ops.append(0, "id-2", [flatEvent(~id="id-2", ~seq=0, ~eventType="Created", ~msgId="m2")])
      let _ = await ops.append(1, "id-1", [flatEvent(~id="id-1", ~seq=1, ~eventType="Renamed", ~msgId="m3")])

      let (receivedA, handlerA) = makeHandler()
      let (receivedB, handlerB) = makeHandler()
      let upperBound = ProjectionCheckpoint.maxPosition(db, ProjectionPending.Aggregate)
      expect(upperBound)->toBe(3)

      await ProjectionCheckpoint.runCatchup(
        ~db,
        ~upperBound,
        ~dcbUpperBound=0,
        ~handlers=[("RM-A", handlerA), ("RM-B", handlerB)],
      )

      expect(receivedA->Array.map(msgIdOfEnvelope))->toEqual(["m1", "m2", "m3"])
      expect(receivedB->Array.map(msgIdOfEnvelope))->toEqual(["m1", "m2", "m3"])
      expect(ProjectionCheckpoint.getPosition(db, "RM-A"))->toBe(3)
      expect(ProjectionCheckpoint.getPosition(db, "RM-B"))->toBe(3)

      // Second startup: checkpoints are current — nothing is redelivered.
      await ProjectionCheckpoint.runCatchup(
        ~db,
        ~upperBound=ProjectionCheckpoint.maxPosition(db, ProjectionPending.Aggregate),
        ~dcbUpperBound=0,
        ~handlers=[("RM-A", handlerA), ("RM-B", handlerB)],
      )
      expect(receivedA->Array.length)->toBe(3)
      expect(receivedB->Array.length)->toBe(3)
    })

    testPromise("a fresh database still stamps checkpoint rows at 0", async () => {
      // Regression (caught by the platform smoke run): with upperBound = 0 and
      // no events, runCatchup must still CREATE the rows — the runtime
      // advanceAll only lifts existing rows, so a missing row would make every
      // subsequent startup redeliver the whole history.
      ProjectionPending.reset()
      let db = makeFreshDb()
      let (_, handler) = makeHandler()
      await ProjectionCheckpoint.runCatchup(~db, ~upperBound=0, ~dcbUpperBound=0, ~handlers=[("RM-Fresh", handler)])
      let stamped =
        db
        ->SqliteDriver.prepare(
          "SELECT COUNT(*) AS c FROM projection_checkpoint WHERE read_model = ?",
        )
        ->SqliteDriver.get([JSON.Encode.string("RM-Fresh")])
      expect(stamped->Option.flatMap(r => r->Dict.get("c")))->toEqual(
        Some(JSON.Encode.float(1.0)),
      )
      expect(ProjectionCheckpoint.getPosition(db, "RM-Fresh"))->toBe(0)
    })

    testPromise("a read model without a checkpoint row is seeded from history", async () => {
      ProjectionPending.reset()
      module TestBus = LocalBus.Make()
      module DbProvider = {
        let db = makeFreshDb()
      }
      module Storage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
      let s = Storage.make(~name="agg", ~owner=None, ~opts)
      let ops = await s.operations->TestRunner.resolve
      let db = DbProvider.db

      let _ = await ops.append(0, "id-1", [flatEvent(~id="id-1", ~seq=0, ~eventType="Created", ~msgId="m1")])

      // First session knows only RM-A.
      let (receivedA, handlerA) = makeHandler()
      await ProjectionCheckpoint.runCatchup(
        ~db,
        ~upperBound=ProjectionCheckpoint.maxPosition(db, ProjectionPending.Aggregate),
        ~dcbUpperBound=0,
        ~handlers=[("RM-A", handlerA)],
      )
      expect(receivedA->Array.length)->toBe(1)

      // A read model added later starts at 0 and receives the full history;
      // the existing one stays quiet.
      let (receivedNew, handlerNew) = makeHandler()
      await ProjectionCheckpoint.runCatchup(
        ~db,
        ~upperBound=ProjectionCheckpoint.maxPosition(db, ProjectionPending.Aggregate),
        ~dcbUpperBound=0,
        ~handlers=[("RM-A", handlerA), ("RM-New", handlerNew)],
      )
      expect(receivedA->Array.length)->toBe(1)
      expect(receivedNew->Array.map(msgIdOfEnvelope))->toEqual(["m1"])
      expect(ProjectionCheckpoint.getPosition(db, "RM-New"))->toBe(1)
    })
  })

  describe("DCB axis", () => {
    testPromise(
      "catch-up delivers missed DCB events with the tag-derived entityId, exactly once",
      async () => {
        ProjectionPending.reset()
        let db = makeFreshDb()
        let dcbOps = await makeDcbStorage(db, ~name="OrderingDcbEventLog")

        // First tag supplies the envelope id (publish-path parity); a tagless
        // event falls back to the log name.
        let _ = await dcbOps.append(
          [
            dcbEvent(
              ~eventType="OrderPlaced",
              ~tags=[{key: "orderId", value: "o-1"}, {key: "productId", value: "p-1"}],
              ~data=[("qty", JSON.Encode.int(2))],
              ~msgId="d1",
            ),
          ],
          ~condition=?None,
        )
        let _ = await dcbOps.append(
          [dcbEvent(~eventType="MaintenanceRan", ~tags=[], ~msgId="d2")],
          ~condition=?None,
        )

        let (received, handler) = makeHandler()
        await ProjectionCheckpoint.runCatchup(
          ~db,
          ~upperBound=0,
          ~dcbUpperBound=ProjectionCheckpoint.maxPosition(db, ProjectionPending.Dcb),
          ~handlers=[("SV", handler)],
        )

        expect(received->Array.map(msgIdOfEnvelope))->toEqual(["d1", "d2"])
        expect(received->Array.map(idOfEnvelope))->toEqual(["o-1", "OrderingDcbEventLog"])
        // The event payload is the same combineMessage form the live publish uses.
        expect(
          received
          ->Array.get(0)
          ->Option.flatMap(JSON.Decode.object)
          ->Option.flatMap(d => d->Dict.get("event")),
        )->toEqual(
          Some(
            JSON.Encode.object(
              Dict.fromArray([
                ("TAG", JSON.Encode.string("OrderPlaced")),
                ("qty", JSON.Encode.int(2)),
              ]),
            ),
          ),
        )
        // Axis rows are independent: the DCB row advanced, the aggregate row
        // stamped at its own (empty) bound.
        expect(ProjectionCheckpoint.getPosition(db, "dcb:SV"))->toBe(2)
        expect(ProjectionCheckpoint.getPosition(db, "SV"))->toBe(0)

        // Second startup: nothing redelivered.
        await ProjectionCheckpoint.runCatchup(
          ~db,
          ~upperBound=0,
          ~dcbUpperBound=ProjectionCheckpoint.maxPosition(db, ProjectionPending.Dcb),
          ~handlers=[("SV", handler)],
        )
        expect(received->Array.length)->toBe(2)
      },
    )

    testPromise("the two axes' watermarks are independent", async () => {
      ProjectionPending.reset()
      ProjectionPending.enableTracking()
      module TestBus = LocalBus.Make()
      module DbProvider = {
        let db = makeFreshDb()
      }
      module AggStorage = EventLogStorage_Sqlite.Make(TestBus, DbProvider)
      let aggS = AggStorage.make(~name="agg", ~owner=None, ~opts)
      let aggOps = await aggS.operations->TestRunner.resolve
      let db = DbProvider.db
      let dcbOps = await makeDcbStorage(db, ~name="dcb-log")

      // One pending append on each axis.
      let _ = await aggOps.append(
        0,
        "id-1",
        [flatEvent(~id="id-1", ~seq=0, ~eventType="Created", ~msgId="agg1")],
      )
      let _ = await dcbOps.append(
        [dcbEvent(~eventType="OrderPlaced", ~tags=[{key: "orderId", value: "o-1"}], ~msgId="dcb1")],
        ~condition=?None,
      )
      ProjectionCheckpoint.setPosition(db, "RM", 0)
      ProjectionCheckpoint.setPosition(db, "dcb:RM", 0)

      // Only the DCB batch completes: its axis advances, the aggregate axis
      // stays capped by its own pending append.
      ProjectionCheckpoint.completePublished(db, ["dcb1"])
      expect(ProjectionCheckpoint.getPosition(db, "dcb:RM"))->toBe(1)
      expect(ProjectionCheckpoint.getPosition(db, "RM"))->toBe(0)

      ProjectionCheckpoint.completePublished(db, ["agg1"])
      expect(ProjectionCheckpoint.getPosition(db, "RM"))->toBe(1)
      ProjectionPending.reset()
    })
  })
})
