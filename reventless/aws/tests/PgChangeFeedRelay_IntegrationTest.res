// Live-Postgres integration suite for the change-feed relay (B2.4).
//
// Run via `pnpm run test:integration:pg` (boots a Postgres sidecar, runs the PG
// suites serially, tears down). Excluded from the default parallel `pnpm test`;
// self-skips unless PG_URL is set (the script exports it).
//
// Exercises the deployed propagation path end-to-end minus AWS: DCB events are
// appended to a real `dcb_event` log (classic events to `event_log`), then
// `PgChangeFeedRelay_Runtime.relayWithPool` / `relayClassicWithPool` drains the
// feed, transforms each event into the EventCollector `{id, meta, event}` body,
// and hands the batch to an injected `sendBatch` (standing in for the SQS
// SendMessage the entry point wires). Asserts the emitted bodies, the partition-tag
// `id` derivation, and the checkpoints (a second drain sees nothing new; per-log
// subscribers stay isolated).

open JestGlobals
open ReventlessCore
open Reventless

let opts: Pulumi.CustomResourceOptions.t = {}

let jsonObj = pairs => JSON.Encode.object(Dict.fromArray(pairs))

let stored = (eventType, tags, data): DcbEventLog_Adapter.rawStoredEvent => {
  eventType,
  data,
  tags,
  meta: ReventlessCore.Message.generateMeta(~service="relay-it"),
}

// Collect every JSON body handed to sendBatch across all drain pages.
let capturingSendBatch = sink => async jsons => sink := sink.contents->Array.concat(jsons)

let idOf = json =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get("id"))->Option.flatMap(JSON.Decode.string)

switch NodeProcess.env->Dict.get("PG_URL") {
| None =>
  testSync("Postgres relay integration (skipped — set PG_URL to run)", () =>
    expect(true)->toBe(true)
  )
| Some(url) =>
  let pool = ReventlessPostgres.PgDriver.makePool({connectionString: url})

  let makeLog = name =>
    ReventlessPostgres.DcbEventLogStorage_Postgres.makeStorage(
      ~pool,
      ~name,
      ~indexes=[],
      ~partitionTag=DcbTag.Simple({key: "orderId"}),
      ~opts,
    )

  beforeAllAsync(async () => {
    await ReventlessPostgres.PgSchema.ensureSchema(pool)
    await ReventlessPostgres.PgSchema.truncateAll(pool)
  })
  afterAll(() => {
    let _ = pool->ReventlessPostgres.PgDriver.endPool
  })

  describe("PgChangeFeedRelay end-to-end (append → drain → EventCollector bodies)", () => {
    testPromise("relays each appended DCB event as an {id, meta, event} body", async () => {
      let (_n, ops, _s) = makeLog("relay-basic")
      let mk = i =>
        stored("OrderPlaced", [{key: "orderId", value: "o-1"}], jsonObj([("i", JSON.Encode.int(i))]))
      let _ = await ops.append([mk(0), mk(1), mk(2)])

      let sink = ref([])
      let processed = await PgChangeFeedRelay_Runtime.relayWithPool(
        ~pool,
        ~logName="relay-basic",
        ~subscriber="relay-it",
        ~sendBatch=capturingSendBatch(sink),
      )

      expect(processed)->toBe(3)
      expect(sink.contents->Array.length)->toBe(3)

      // Every body carries the derived id, the event type, and the producing service.
      let first = sink.contents->Array.getUnsafe(0)
      expect(idOf(first))->toEqual(Some("orderId:o-1"))
      let obj = first->JSON.Decode.object->Option.getOrThrow
      expect(obj->Dict.get("event")->Option.getOrThrow->JSON.stringify->String.includes("OrderPlaced"))->toBe(true)
      let metaObj = obj->Dict.get("meta")->Option.flatMap(JSON.Decode.object)->Option.getOrThrow
      expect(metaObj->Dict.get("service"))->toEqual(Some(JSON.Encode.string("relay-it")))
    })

    testPromise("checkpoints — a second drain from the same subscriber sees nothing new", async () => {
      let (_n, ops, _s) = makeLog("relay-checkpoint")
      let mk = i => stored("Fed", [{key: "orderId", value: "f"}], jsonObj([("i", JSON.Encode.int(i))]))
      let _ = await ops.append([mk(0), mk(1)])

      let sink = ref([])
      let first = await PgChangeFeedRelay_Runtime.relayWithPool(
        ~pool,
        ~logName="relay-checkpoint",
        ~subscriber="relay-it",
        ~sendBatch=capturingSendBatch(sink),
      )
      expect(first)->toBe(2)

      let second = await PgChangeFeedRelay_Runtime.relayWithPool(
        ~pool,
        ~logName="relay-checkpoint",
        ~subscriber="relay-it",
        ~sendBatch=capturingSendBatch(sink),
      )
      expect(second)->toBe(0)
      // No extra bodies were emitted on the second pass.
      expect(sink.contents->Array.length)->toBe(2)
    })

    testPromise("classic: relays each appended event_log event as an {id, meta, event} body", async () => {
      let (_n, ops, _s) =
        ReventlessPostgres.EventLogStorage_Postgres.makeStorage(
          ~pool,
          ~name="ClassicRelayBasicEventLog",
          ~opts=(),
        )
      // The flat on-disk item the classic append stores verbatim — same shape the
      // DynamoDB path puts (id, position, event, data, decomposed meta).
      let flatItem = (~id, ~seq, ~eventType, ~data) =>
        [
          ("id", JSON.Encode.string(id)),
          ("position", JSON.Encode.string(seq->Int.toString->String.padStart(9, "0"))),
          ("event", JSON.Encode.string(eventType)),
          ("data", data),
        ]
        ->Array.concat(
          ReventlessCore.Message.generateMeta(~service="relay-it")->ReventlessCore.Message.decomposeMeta,
        )
        ->Dict.fromArray
        ->JSON.Encode.object
      let _ = await ops.append(
        0,
        "agg-1",
        [
          flatItem(~id="agg-1", ~seq=0, ~eventType="NameUpdated", ~data=jsonObj([("n", JSON.Encode.int(0))])),
          flatItem(~id="agg-1", ~seq=1, ~eventType="NameUpdated", ~data=jsonObj([("n", JSON.Encode.int(1))])),
        ],
      )

      let sink = ref([])
      let processed = await PgChangeFeedRelay_Runtime.relayClassicWithPool(
        ~pool,
        ~logName="ClassicRelayBasicEventLog",
        ~subscriber="relay-it:ClassicRelayBasicEventLog",
        ~sendBatch=capturingSendBatch(sink),
      )

      expect(processed)->toBe(2)
      expect(sink.contents->Array.length)->toBe(2)
      let first = sink.contents->Array.getUnsafe(0)
      expect(idOf(first))->toEqual(Some("agg-1"))
      let obj = first->JSON.Decode.object->Option.getOrThrow
      expect(
        obj->Dict.get("event")->Option.getOrThrow->JSON.stringify->String.includes("NameUpdated"),
      )->toBe(true)
      let metaObj = obj->Dict.get("meta")->Option.flatMap(JSON.Decode.object)->Option.getOrThrow
      expect(metaObj->Dict.get("service"))->toEqual(Some(JSON.Encode.string("relay-it")))

      // Checkpointed: a second drain from the same subscriber sees nothing new.
      let second = await PgChangeFeedRelay_Runtime.relayClassicWithPool(
        ~pool,
        ~logName="ClassicRelayBasicEventLog",
        ~subscriber="relay-it:ClassicRelayBasicEventLog",
        ~sendBatch=capturingSendBatch(sink),
      )
      expect(second)->toBe(0)
      expect(sink.contents->Array.length)->toBe(2)
    })

    testPromise("classic: per-log subscribers keep checkpoints isolated across logs", async () => {
      // event_log_subscription keys by subscriber alone. With a SHARED subscriber,
      // draining log A after log B's events were appended would save a cursor past
      // B's rows and silently skip them — the clobber the per-log subscriber fixes.
      let mkOps = name => {
        let (_n, ops, _s) =
          ReventlessPostgres.EventLogStorage_Postgres.makeStorage(~pool, ~name, ~opts=())
        ops
      }
      let opsB = mkOps("ClassicRelayIsoBEventLog")
      let opsA = mkOps("ClassicRelayIsoAEventLog")
      let meta = () =>
        ReventlessCore.Message.generateMeta(~service="relay-it")->ReventlessCore.Message.decomposeMeta
      let item = (id, eventType) =>
        [
          ("id", JSON.Encode.string(id)),
          ("position", JSON.Encode.string("000000000")),
          ("event", JSON.Encode.string(eventType)),
          ("data", jsonObj([])),
        ]
        ->Array.concat(meta())
        ->Dict.fromArray
        ->JSON.Encode.object
      // B's event commits FIRST (lower global_seq), then A's.
      let _ = await opsB.append(0, "b-1", [item("b-1", "BHappened")])
      let _ = await opsA.append(0, "a-1", [item("a-1", "AHappened")])

      // Drain A first — its checkpoint lands PAST B's rows in global_seq order.
      let sinkA = ref([])
      let drainedA = await PgChangeFeedRelay_Runtime.relayClassicWithPool(
        ~pool,
        ~logName="ClassicRelayIsoAEventLog",
        ~subscriber="relay-it:ClassicRelayIsoAEventLog",
        ~sendBatch=capturingSendBatch(sinkA),
      )
      expect(drainedA)->toBe(1)

      // B still sees its event because its subscriber has its own checkpoint.
      let sinkB = ref([])
      let drainedB = await PgChangeFeedRelay_Runtime.relayClassicWithPool(
        ~pool,
        ~logName="ClassicRelayIsoBEventLog",
        ~subscriber="relay-it:ClassicRelayIsoBEventLog",
        ~sendBatch=capturingSendBatch(sinkB),
      )
      expect(drainedB)->toBe(1)
      expect(idOf(sinkB.contents->Array.getUnsafe(0)))->toEqual(Some("b-1"))
    })

    testPromise("partitionTag pins the id to its tag on a multi-tag event", async () => {
      let (_n, ops, _s) =
        ReventlessPostgres.DcbEventLogStorage_Postgres.makeStorage(
          ~pool,
          ~name="relay-pt",
          ~indexes=[],
          ~partitionTag=DcbTag.Simple({key: "customerId"}),
          ~opts,
        )
      let ev =
        stored(
          "OrderPlaced",
          [{key: "orderId", value: "o-9"}, {key: "customerId", value: "c-9"}],
          jsonObj([("n", JSON.Encode.int(1))]),
        )
      let _ = await ops.append([ev])

      // The relay receives the sury-encoded partition tag exactly as the builder emits it.
      let partitionTagJson =
        DcbTag.Simple({key: "customerId"})->S.reverseConvertToJsonOrThrow(
          Reventless.DcbTag.derivedPartitionTagSchema,
        )

      let sink = ref([])
      let _ = await PgChangeFeedRelay_Runtime.relayWithPool(
        ~pool,
        ~logName="relay-pt",
        ~subscriber="relay-it",
        ~partitionTagJson,
        ~sendBatch=capturingSendBatch(sink),
      )
      // Without the tag the id would be "orderId:o-9" (first tag); the tag pins it.
      expect(idOf(sink.contents->Array.getUnsafe(0)))->toEqual(Some("customerId:c-9"))
    })
  })
}
