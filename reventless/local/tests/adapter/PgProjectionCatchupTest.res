// Postgres startup projection catch-up (#1): under Backend.Postgres the read
// models are in-memory, so on restart they must be rebuilt by replaying the
// durable pg event log through the projection handlers.
//
// Skipped unless PG_URL is set. Verifies:
//   - every persisted classic + DCB event is redelivered as a well-formed
//     {id, meta, event} envelope, in order;
//   - the pre-session head bound excludes events appended after capture (this
//     session's live-delivered events are never redelivered).

open JestGlobals

@val external processEnv: dict<string> = "process.env"
let opts: Pulumi.CustomResourceOptions.t = {}

// Flat stored aggregate event — the exact shape EventLog_Operations.encodeEvent'
// persists (envelope fields + meta flattened to top level).
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

let idOf = (json: JSON.t) =>
  json
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("id"))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("<none>")

let recorder = () => {
  let received: array<JSON.t> = []
  let handler = (json: JSON.t, _ctx: unit) => {
    received->Array.push(json)
    Promise.resolve()
  }
  (received, handler)
}

switch processEnv->Dict.get("PG_URL") {
| None => testSync("Postgres projection catch-up (skipped — set PG_URL)", () => expect(true)->toBe(true))
| Some(url) =>
  let pool = ReventlessPostgres.PgDriver.makePool({connectionString: url})

  beforeAllAsync(async () => await ReventlessPostgres.PgSchema.ensureSchema(pool))
  afterAll(() => ignore(pool->ReventlessPostgres.PgDriver.endPool))

  // No beforeEachAsync binding exists; reset at the top of each test for isolation.
  let reset = async () => await ReventlessPostgres.PgSchema.truncateAll(pool)

  let classicOps = () => {
    let (_, ops, _) = ReventlessPostgres.EventLogStorage_Postgres.makeStorage(
      ~pool,
      ~name="catchup-agg",
      ~opts,
    )
    ops
  }
  let dcbOps = () => {
    let (_, ops, _) = ReventlessPostgres.DcbEventLogStorage_Postgres.makeStorage(
      ~pool,
      ~name="catchup-dcb",
      ~indexes=[],
      ~partitionTag=Reventless.DcbTag.Simple({key: "k"}),
      ~opts,
    )
    ops
  }

  describe("PgProjectionCatchup", () => {
    testPromise("replays every persisted classic + DCB event as an envelope", async () => {
      await reset()
      let agg = classicOps()
      let _ = await agg.append(0, "p1", [flatEvent(~id="p1", ~seq=0, ~eventType="Added", ~msgId="a0")])
      let _ = await agg.append(1, "p1", [flatEvent(~id="p1", ~seq=1, ~eventType="Renamed", ~msgId="a1")])

      let dcb = dcbOps()
      let _ = await dcb.append([dcbEvent(~eventType="Placed", ~tags=[{key: "orderId", value: "o1"}], ~msgId="d0")])
      let _ = await dcb.append([dcbEvent(~eventType="Paid", ~tags=[{key: "orderId", value: "o2"}], ~msgId="d1")])

      let bounds = await PgProjectionCatchup.captureBounds(pool)
      let (received, handler) = recorder()
      await PgProjectionCatchup.runCatchup(~pool, ~bounds, ~handlers=[("rm", handler)])

      // 2 classic + 2 dcb = 4 well-formed envelopes (None envelopes aren't delivered).
      expect(received->Array.length)->toBe(4)
      // Classic events keep their aggregate id, in order.
      expect(idOf(received->Array.getUnsafe(0)))->toBe("p1")
      expect(idOf(received->Array.getUnsafe(1)))->toBe("p1")
      // DCB events derive id from the first tag value.
      expect(idOf(received->Array.getUnsafe(2)))->toBe("o1")
      expect(idOf(received->Array.getUnsafe(3)))->toBe("o2")
    })

    testPromise("the pre-session bound excludes events appended after capture", async () => {
      await reset()
      let agg = classicOps()
      let _ = await agg.append(0, "p1", [flatEvent(~id="p1", ~seq=0, ~eventType="Added", ~msgId="a0")])
      let _ = await agg.append(1, "p1", [flatEvent(~id="p1", ~seq=1, ~eventType="Renamed", ~msgId="a1")])

      // Snapshot the head BEFORE the "this-session" append below.
      let bounds = await PgProjectionCatchup.captureBounds(pool)

      // This event is > the captured bound — it stands in for a live-delivered
      // this-session append and must NOT be redelivered by catch-up.
      let _ = await agg.append(2, "p1", [flatEvent(~id="p1", ~seq=2, ~eventType="Archived", ~msgId="a2")])

      let (received, handler) = recorder()
      await PgProjectionCatchup.runCatchup(~pool, ~bounds, ~handlers=[("rm", handler)])

      expect(received->Array.length)->toBe(2)
    })

    testPromise("delivers each event to every handler", async () => {
      await reset()
      let agg = classicOps()
      let _ = await agg.append(0, "p1", [flatEvent(~id="p1", ~seq=0, ~eventType="Added", ~msgId="a0")])

      let bounds = await PgProjectionCatchup.captureBounds(pool)
      let (r1, h1) = recorder()
      let (r2, h2) = recorder()
      await PgProjectionCatchup.runCatchup(~pool, ~bounds, ~handlers=[("rm1", h1), ("rm2", h2)])

      expect(r1->Array.length)->toBe(1)
      expect(r2->Array.length)->toBe(1)
    })
  })
}
