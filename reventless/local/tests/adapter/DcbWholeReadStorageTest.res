// A decision reads a small kind whole: on both local backends the kind clause reads every event
// of the kind, whatever partition holds it, and a write of the kind between the read and the
// append conflicts.

open JestGlobals

let _ = TestRunner.setup()
let opts: Pulumi.CustomResourceOptions.t = {}

let runUnderSqlite = async fn => {
  let db = SqliteDriver.openDb(~path=":memory:")
  BackendState.setSqlite(~db, ~path=":memory:")
  await fn()
  BackendState.setMemory()
  db->SqliteDriver.close
}

let feeSet = (option): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
  eventType: "DeliveryFeeSet",
  data: JSON.Encode.object(Dict.fromArray([("deliveryOptionId", JSON.Encode.string(option))])),
  tags: [{key: "deliveryOptionId", value: option}, Reventless.DcbTag.kindTag("DeliveryFeeSet")],
  meta: ReventlessCore.Message.generateMeta(~service="test"),
}

let orderPlaced = (orderId): ReventlessCore.DcbEventLog_Adapter.rawStoredEvent => {
  eventType: "OrderPlaced",
  data: JSON.Encode.object(Dict.fromArray([("orderId", JSON.Encode.string(orderId))])),
  tags: [{key: "orderId", value: orderId}],
  meta: ReventlessCore.Message.generateMeta(~service="test"),
}

// What PlaceOrder's command builds: its order, and the fees read whole.
let quoteQuery = (orderId): Reventless.DcbTag.query => [
  {eventTypes: ["OrderPlaced"], tags: [{key: "orderId", value: orderId}]},
  {eventTypes: ["DeliveryFeeSet"], tags: [Reventless.DcbTag.kindTag("DeliveryFeeSet")]},
]

let partitionTag = Reventless.DcbTag.ByEventType(
  Dict.fromArray([("DeliveryFeeSet", "deliveryOptionId"), ("OrderPlaced", "orderId")]),
)

let outcome = result =>
  switch result {
  | Ok(_) => "ok"
  | Error(ReventlessInfra.DcbEventLog.Conflict) => "conflict"
  | Error(StorageFailure(m)) => m
  }

let cases = async (~name) => {
  module TestBus = LocalBus.Make()
  module Storage = LocalDcbEventLogStorage.Make(TestBus)
  let s = Storage.make(
    ~name,
    ~indexes=["tag_deliveryOptionId", `tag_${Reventless.DcbTag.kindTagKey}`],
    ~partitionTag,
    ~crossPartitionTagKeys=[Reventless.DcbTag.kindTagKey],
    ~opts,
  )
  let ops = await s.operations->TestRunner.resolve
  let _ = await ops.append([feeSet("standard")])
  let _ = await ops.append([feeSet("express")])

  // Every fee is read, though no tag of the command names a delivery option.
  let read = await ops.read(~query=quoteQuery("o1"))
  let read = read.events->Array.map(e => e.eventType)
  let head = (await ops.read(~query=quoteQuery("o1"))).headPosition

  // Nothing written since: the append goes through.
  let quiet = await ops.append(
    [orderPlaced("o1")],
    ~condition={query: quoteQuery("o1"), after: ?head},
  )

  // A fee set between the read and the append: the append conflicts.
  let head = (await ops.read(~query=quoteQuery("o2"))).headPosition
  let _ = await ops.append([feeSet("standard")])
  let raced = await ops.append(
    [orderPlaced("o2")],
    ~condition={query: quoteQuery("o2"), after: ?head},
  )
  (read, quiet->outcome, raced->outcome)
}

describe("a decision reads a small kind whole", () => {
  testPromise(
    "in memory: every event of the kind is read, and a write of it conflicts",
    async () => {
      let (read, quiet, raced) = await cases(~name="dcb-whole-memory")
      expect(read)->toEqual(["DeliveryFeeSet", "DeliveryFeeSet"])
      expect(quiet)->toBe("ok")
      expect(raced)->toBe("conflict")
    },
  )

  testPromise("in SQLite: every event of the kind is read, and a write of it conflicts", async () =>
    await runUnderSqlite(
      async () => {
        let (read, quiet, raced) = await cases(~name="dcb-whole-sqlite")
        expect(read)->toEqual(["DeliveryFeeSet", "DeliveryFeeSet"])
        expect(quiet)->toBe("ok")
        expect(raced)->toBe("conflict")
      },
    )
  )
})
