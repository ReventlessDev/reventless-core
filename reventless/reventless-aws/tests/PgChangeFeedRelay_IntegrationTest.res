// Live-Postgres integration suite for the change-feed relay (B2.4).
//
// Skipped unless PG_URL is set, so the default `pnpm test` stays dependency-free.
// Run against a real database with e.g.:
//   PG_URL=postgres://postgres:postgres@localhost:5432/postgres pnpm test
//
// Exercises the deployed propagation path end-to-end minus AWS: DCB events are
// appended to a real `dcb_event` log, then `PgChangeFeedRelay_Runtime.relayWithPool`
// drains the feed, transforms each event into the EventCollector `{id, meta, event}`
// body, and hands the batch to an injected `sendBatch` (standing in for the SQS
// SendMessage the entry point wires). Asserts the emitted bodies, the partition-tag
// `id` derivation, and the checkpoint (a second drain sees nothing new).

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
  meta: ReventlessCore.Message.generateMeta(~service="relay-it"),
}

// Collect every JSON body handed to sendBatch across all drain pages.
let capturingSendBatch = sink => async jsons => sink := sink.contents->Array.concat(jsons)

let idOf = json =>
  json->JSON.Decode.object->Option.flatMap(o => o->Dict.get("id"))->Option.flatMap(JSON.Decode.string)

switch processEnv->Dict.get("PG_URL") {
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
