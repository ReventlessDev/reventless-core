// Round-trips `StoredEvent.storedEvent` (the on-disk envelope both the EventLog
// and DcbEventLog backends serialize through). The other half of the C4 sury
// absent-vs-null audit: `tags` is `S.option(S.array(...))`. Unlike the union
// case in interop's `Resource` (where a plain `option` payload broke
// serialization), `tags` is an OPTIONAL RECORD FIELD inside `S.object`, where
// `S.option` is the correct idiom, and now the only one in this repo outside
// `Offload`'s either-or codec. These pin that both the DcbEventLog shape (`tags` present)
// and the Aggregate EventLog shape (`tags` absent) round-trip cleanly.

open JestGlobals

let meta: Message.meta = {
  service: "catalog",
  time: "2026-07-03T00:00:00.000Z",
  msgId: "m1",
  correlationId: "m1",
}

let roundTrip = (ev: StoredEvent.storedEvent<string>) =>
  expect(StoredEvent.decode(StoredEvent.encode(ev, S.string), S.string))->toEqual(ev)

describe("StoredEvent round-trip", () => {
  testSync("DcbEventLog shape — tags present", () =>
    roundTrip({
      id: "cat-1",
      position: "1700000000000-abc",
      event: "CategoryAdded",
      data: JSON.parseOrThrow(`{"categoryId":"cat-1","name":"Electronics"}`),
      meta,
      recordedAt: "2026-07-03T00:00:00.000Z",
      tags: [{key: "categoryId", value: "cat-1"}],
    })
  )

  testSync("DcbEventLog shape — multiple tags", () =>
    roundTrip({
      id: "order-9#prod-3",
      position: "1700000000001-def",
      event: "OrderPlaced",
      data: JSON.parseOrThrow(`{"orderId":"order-9"}`),
      meta,
      recordedAt: "2026-07-03T00:00:00.000Z",
      tags: [{key: "orderId", value: "order-9"}, {key: "productId", value: "prod-3"}],
    })
  )

  testSync("Aggregate EventLog shape — tags absent", () =>
    roundTrip({
      id: "agg-1",
      position: "0000000000",
      event: "ProductAdded",
      data: JSON.parseOrThrow(`{"productId":"p1"}`),
      meta,
      recordedAt: "2026-07-03T00:00:00.000Z",
    })
  )

  testSync("empty tags array is preserved distinct from absent", () =>
    roundTrip({
      id: "cat-2",
      position: "1700000000002-ghi",
      event: "CategoryArchived",
      data: JSON.parseOrThrow(`{"categoryId":"cat-2"}`),
      meta,
      recordedAt: "2026-07-03T00:00:00.000Z",
      tags: [],
    })
  )
})
