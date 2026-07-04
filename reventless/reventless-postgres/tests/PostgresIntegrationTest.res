// Live-Postgres integration + concurrency suite (Phase F2).
//
// Skipped unless PG_URL is set, so the default `pnpm test` stays dependency-free.
// Run against a real database with e.g.:
//   PG_URL=postgres://postgres:postgres@localhost:5432/postgres pnpm test
//
// Covers the concurrency-critical core that nothing else in the repo has:
//   - classic OCC append (success, gap/stale → Conflict, replay)
//   - DCB append + xmin-fenced read + conditional-append conflict
//   - write-skew: two genuinely concurrent conditional appends on one boundary —
//     exactly one commits, the other conflicts cleanly (the anomaly the advisory
//     locks close)
//   - both #AdvisoryLocks and #RowLocks strategies

open JestGlobals
open ReventlessCore
open Reventless

@val external processEnv: dict<string> = "process.env"
let opts: Pulumi.CustomResourceOptions.t = {}

let jsonObj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

let stored = (eventType, tags, data): DcbEventLog_Adapter.rawStoredEvent => {
  eventType,
  data,
  tags,
  meta: ReventlessCore.Message.generateMeta(~service="pg-test"),
}

let evJson = (msgId, v) =>
  jsonObj([("msgId", JSON.Encode.string(msgId)), ("v", JSON.Encode.int(v))])

switch processEnv->Dict.get("PG_URL") {
| None =>
  testSync("Postgres integration (skipped — set PG_URL to run)", () => expect(true)->toBe(true))
| Some(url) =>
  let pool = PgDriver.makePool({connectionString: url})

  beforeAllAsync(async () => {
    await PgSchema.ensureSchema(pool)
    await PgSchema.truncateAll(pool)
  })
  afterAll(() => {
    let _ = pool->PgDriver.endPool
  })

  describe("classic OCC event log", () => {
    testPromise("append, replay, and conflict on wrong seq", async () => {
      let (_n, ops, _s) = EventLogStorage_Postgres.makeStorage(~pool, ~name="ct-orders", ~opts)

      let r0 = await ops.append(0, "agg-1", [evJson("m0", 1), evJson("m1", 2)])
      switch r0 {
      | Ok() => expect(true)->toBe(true)
      | Error(_) => expect("append")->toBe("ok")
      }

      // Stale seq (0 again) → Conflict.
      let rStale = await ops.append(0, "agg-1", [evJson("m2", 3)])
      switch rStale {
      | Error(EventLog.Conflict) => expect(true)->toBe(true)
      | _ => expect("stale")->toBe("conflict")
      }

      // Gap seq (5) → Conflict.
      let rGap = await ops.append(5, "agg-1", [evJson("m3", 4)])
      switch rGap {
      | Error(EventLog.Conflict) => expect(true)->toBe(true)
      | _ => expect("gap")->toBe("conflict")
      }

      // Correct next seq (2) → Ok.
      let rNext = await ops.append(2, "agg-1", [evJson("m4", 5)])
      switch rNext {
      | Ok() => expect(true)->toBe(true)
      | Error(_) => expect("next")->toBe("ok")
      }

      let evs = await ops.replay("agg-1")
      expect(evs->Array.length)->toBe(3)

      // Empty append is a no-op, never a conflict.
      let rEmpty = await ops.append(3, "agg-1", [])
      switch rEmpty {
      | Ok() => expect(true)->toBe(true)
      | Error(_) => expect("empty")->toBe("ok")
      }
    })
  })

  describe("DCB event log", () => {
    let makeLog = name =>
      DcbEventLogStorage_Postgres.makeStorage(
        ~pool,
        ~name,
        ~indexes=[],
        ~partitionTag=DcbTag.Simple({key: "k"}),
        ~opts,
      )

    testPromise("append + read round-trips events with tags", async () => {
      let (_n, ops, _s) = makeLog("dcb-rt")
      let e1 = stored("ItemAdded", [{key: "itemId", value: "x1"}], jsonObj([("n", JSON.Encode.string("w"))]))
      let r = await ops.append([e1])
      switch r {
      | Ok(_) => expect(true)->toBe(true)
      | Error(m) => expect(m)->toBe("ok")
      }
      let read = await ops.read(~query=[])
      expect(read.events->Array.length)->toBe(1)
      let first = read.events->Array.getUnsafe(0)
      expect(first.eventType)->toBe("ItemAdded")
      expect((first.tags->Array.getUnsafe(0)).key)->toBe("itemId")
      expect((first.tags->Array.getUnsafe(0)).value)->toBe("x1")
    })

    testPromise("conditional append conflicts when the boundary already has an event", async () => {
      let (_n, ops, _s) = makeLog("dcb-cond")
      let mk = who => stored("Reserved", [{key: "seatId", value: "s1"}], jsonObj([("who", JSON.Encode.string(who))]))
      let r1 = await ops.append([mk("a")])
      switch r1 {
      | Ok(_) => expect(true)->toBe(true)
      | Error(_) => expect("first")->toBe("ok")
      }
      // Assert "no Reserved for s1 yet" — must now conflict.
      let cond: DcbTag.appendCondition = {
        query: [{eventTypes: ["Reserved"], tags: [{key: "seatId", value: "s1"}]}],
      }
      let r2 = await ops.append([mk("b")], ~condition=cond)
      switch r2 {
      | Error(ReventlessInfra.DcbEventLog.Conflict) => expect(true)->toBe(true)
      | _ => expect("second")->toBe("conflict")
      }
    })

    let writeSkew = (strategy, logName) =>
      testPromise(`write-skew: exactly one of two concurrent appends wins (${logName})`, async () => {
        let (_n, ops, _s) = DcbEventLogStorage_Postgres.makeStorage(
          ~pool,
          ~name=logName,
          ~indexes=[],
          ~partitionTag=DcbTag.Simple({key: "k"}),
          ~opts,
          ~lockStrategy=strategy,
        )
        let cond: DcbTag.appendCondition = {
          query: [{eventTypes: ["Reserved"], tags: [{key: "seatId", value: "hot"}]}],
        }
        let mk = who => stored("Reserved", [{key: "seatId", value: "hot"}], jsonObj([("who", JSON.Encode.string(who))]))
        // Dispatch BOTH before awaiting either — genuinely concurrent on the pool.
        let p1 = ops.append([mk("a")], ~condition=cond)
        let p2 = ops.append([mk("b")], ~condition=cond)
        let r1 = await p1
        let r2 = await p2
        let isOk = r => switch r {
        | Ok(_) => true
        | _ => false
        }
        let isConflict = r => r == Error(ReventlessInfra.DcbEventLog.Conflict)
        let oks = [r1, r2]->Array.filter(isOk)->Array.length
        let conflicts = [r1, r2]->Array.filter(isConflict)->Array.length
        expect(oks)->toBe(1)
        expect(conflicts)->toBe(1)
        // And only one event actually landed on the boundary.
        let read = await ops.read(~query=[{tags: [{key: "seatId", value: "hot"}]}])
        expect(read.events->Array.length)->toBe(1)
      })

    writeSkew(#AdvisoryLocks, "dcb-skew-advisory")
    writeSkew(#RowLocks, "dcb-skew-rows")

    testPromise("hot tag: N concurrent conditional appends, exactly one wins", async () => {
      let (_n, ops, _s) = makeLog("dcb-hot")
      let cond: DcbTag.appendCondition = {
        query: [{eventTypes: ["Claimed"], tags: [{key: "prizeId", value: "p1"}]}],
      }
      let n = 12
      // Dispatch all N before awaiting any — genuinely concurrent on the pool.
      let promises = Array.make(~length=n, 0)->Array.mapWithIndex((_, i) =>
        ops.append(
          [stored("Claimed", [{key: "prizeId", value: "p1"}], jsonObj([("who", JSON.Encode.int(i))]))],
          ~condition=cond,
        )
      )
      let results = await Promise.all(promises)
      let oks = results->Array.filter(r => switch r {
      | Ok(_) => true
      | _ => false
      })->Array.length
      expect(oks)->toBe(1)
      // No lost updates: exactly one Claimed landed on the boundary.
      let read = await ops.read(~query=[{tags: [{key: "prizeId", value: "p1"}]}])
      expect(read.events->Array.length)->toBe(1)
    })

    testPromise("cursors are monotonic and usable as `after`", async () => {
      let (_n, ops, _s) = makeLog("dcb-cursor")
      let mk = i => stored("Tick", [{key: "streamId", value: "c1"}], jsonObj([("i", JSON.Encode.int(i))]))
      let _ = await ops.append([mk(0)])
      let mid = switch await ops.append([mk(1)]) {
      | Ok(pos) => pos
      | Error(_) => ""
      }
      let _ = await ops.append([mk(2)])
      // Reading after `mid` returns only the events strictly after it.
      let read = await ops.read(~query=[{tags: [{key: "streamId", value: "c1"}]}], ~after=mid)
      expect(read.events->Array.length)->toBe(1)
      expect((read.events->Array.getUnsafe(0)).eventType)->toBe("Tick")
    })
  })

  describe("change feed", () => {
    testPromise("drains all events and checkpoints", async () => {
      let (_n, ops, _s) = DcbEventLogStorage_Postgres.makeStorage(
        ~pool,
        ~name="feed-log",
        ~indexes=[],
        ~partitionTag=DcbTag.Simple({key: "k"}),
        ~opts,
      )
      let mk = i => stored("Fed", [{key: "id", value: "f"}], jsonObj([("i", JSON.Encode.int(i))]))
      let _ = await ops.append([mk(0), mk(1), mk(2)])

      let collected = ref(0)
      let processed = await PgChangeFeed.drain(pool, ~logName="feed-log", ~subscriber="sub-1", ~handle=async evs => {
        collected := collected.contents + evs->Array.length
      })
      expect(processed)->toBe(3)
      expect(collected.contents)->toBe(3)

      // A second drain from the saved checkpoint sees nothing new.
      let again = await PgChangeFeed.drain(pool, ~logName="feed-log", ~subscriber="sub-1", ~handle=async _ => ())
      expect(again)->toBe(0)
    })
  })
}
