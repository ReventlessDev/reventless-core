open JestGlobals

// A realistic DCB feed event as PgChangeFeed.readBatch would surface it.
let sampleEvent: ReventlessCore.DcbEventLog_Adapter.rawSequencedEvent = {
  position: "00000000000000000042:00000000000000000007",
  eventType: "OrderCreated",
  data: [("customerId", JSON.Encode.string("c-1"))]->Dict.fromArray->JSON.Encode.object,
  tags: [{key: "orderId", value: "o-1"}],
  meta: {
    service: "Orders",
    time: "2026-07-05T10:00:00.000Z",
    msgId: "m-1",
    correlationId: "m-1",
  },
  recordedAt: "2026-07-05T10:00:00.000Z",
}

describe("PgChangeFeedRelay_Runtime.toEventCollectorJson", () => {
  testSync("produces the EventCollector {id, meta, event} body from a feed event", () => {
    let json = PgChangeFeedRelay_Runtime.toEventCollectorJson(sampleEvent)->Option.getOrThrow
    let obj = json->JSON.Decode.object->Option.getOrThrow

    // id = derivePartitionKey with no partitionTag → "<firstTag.key>:<value>"
    expect(obj->Dict.get("id"))->toEqual(Some(JSON.Encode.string("orderId:o-1")))

    // event carries the event type + payload (combineMessage encodes a
    // payload-bearing variant as an object, e.g. {"OrderCreated": {...}})
    let eventJson = obj->Dict.get("event")->Option.getOrThrow
    expect(eventJson->JSON.stringify->String.includes("OrderCreated"))->toBe(true)
    expect(eventJson->JSON.stringify->String.includes("c-1"))->toBe(true)

    // meta round-trips the producing service
    let metaObj =
      obj->Dict.get("meta")->Option.flatMap(JSON.Decode.object)->Option.getOrThrow
    expect(metaObj->Dict.get("service"))->toEqual(Some(JSON.Encode.string("Orders")))
  })

  testSync("derives the 'dcb' id when the event carries no tags", () => {
    let noTags = {...sampleEvent, tags: []}
    let json = PgChangeFeedRelay_Runtime.toEventCollectorJson(noTags)->Option.getOrThrow
    let obj = json->JSON.Decode.object->Option.getOrThrow
    expect(obj->Dict.get("id"))->toEqual(Some(JSON.Encode.string("dcb")))
  })
})
