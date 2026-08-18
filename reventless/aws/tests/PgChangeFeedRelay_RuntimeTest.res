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

describe("PgChangeFeedRelay_Runtime partitionTag (B2.3d)", () => {
  let multiTagEvent = {
    ...sampleEvent,
    tags: [{key: "orderId", value: "o-1"}, {key: "customerId", value: "c-9"}],
  }

  testSync("a Simple partitionTag selects its tag for the id, not just the first", () => {
    let pt = Reventless.DcbTag.Simple({key: "customerId"})
    let json =
      PgChangeFeedRelay_Runtime.toEventCollectorJson(multiTagEvent, ~partitionTag=pt)->Option.getOrThrow
    let obj = json->JSON.Decode.object->Option.getOrThrow
    // Without partitionTag the id would be "orderId:o-1" (first tag); the tag
    // pins it to "customerId:c-9".
    expect(obj->Dict.get("id"))->toEqual(Some(JSON.Encode.string("customerId:c-9")))
  })

  testSync("derivedPartitionTag round-trips through the sury schema (relay wire-format)", () => {
    // The relay builder serialises partitionTag with this schema into HANDLER_CONFIG
    // and PgChangeFeedRelay_Runtime.relay parses it back the same way. Guard the
    // round-trip so a schema change can't silently break the id derivation.
    let simple = Reventless.DcbTag.Simple({key: "courseId"})
    let composite =
      Reventless.DcbTag.Composite({keys: ["studentId", "courseId"], seps: [":"]})
    [simple, composite]->Array.forEach(pt => {
      let wire = pt->Reventless.Util_Sury.toJson(Reventless.DcbTag.derivedPartitionTagSchema)
      let back = wire->Reventless.Util_Sury.fromJson(Reventless.DcbTag.derivedPartitionTagSchema)
      expect(back)->toEqual(pt)
    })
  })
})
