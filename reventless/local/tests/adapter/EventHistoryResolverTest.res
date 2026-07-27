// Behavioural tests for the event-history query resolver's pure core —
// position ordering, filtering, and keyset pagination. That is where the
// behaviour lives; the Bus fork around them is two registry lookups.

@@warning("-44")

open JestGlobals

module EH = EventHistoryResolvers_GraphQL

let metaOf = (~user=?, ~time="2026-01-01T00:00:00Z", ()) =>
  Dict.fromArray([
    ("service", JSON.Encode.string("OrderingService")),
    ("time", JSON.Encode.string(time)),
    ("user", user->Option.mapOr(JSON.Encode.null, JSON.Encode.string)),
    ("msgId", JSON.Encode.string("msg-1")),
    ("correlationId", JSON.Encode.string("corr-1")),
    ("causationId", JSON.Encode.null),
  ])->JSON.Encode.object

let rec_ = (~position, ~eventType="OrderPlaced", ~tags=[], ~user=?, ~time="2026-01-01T00:00:00Z", ()): EH.record => {
  position,
  eventType,
  payload: JSON.Encode.object(Dict.make()),
  tags,
  meta: metaOf(~user?, ~time, ()),
  recordedAt: time,
}

let tag = (key, value): Reventless.DcbTag.tag => {key, value}

let args = (~first=?, ~after=?, ~last=?, ~before=?, ()) => {
  let d = Dict.make()
  first->Option.forEach(v => d->Dict.set("first", JSON.Encode.float(v->Int.toFloat)))
  last->Option.forEach(v => d->Dict.set("last", JSON.Encode.float(v->Int.toFloat)))
  after->Option.forEach(v => d->Dict.set("after", JSON.Encode.string(v)))
  before->Option.forEach(v => d->Dict.set("before", JSON.Encode.string(v)))
  JSON.Encode.object(d)
}

let positionsOf = (connection: JSON.t): array<string> =>
  connection
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("edges"))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(edge =>
    edge
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get("node"))
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(d => d->Dict.get("position"))
    ->Option.flatMap(JSON.Decode.string)
  )

let endCursorOf = (connection: JSON.t): option<string> =>
  connection
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("pageInfo"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("endCursor"))
  ->Option.flatMap(JSON.Decode.string)

let hasNextPageOf = (connection: JSON.t): bool =>
  connection
  ->JSON.Decode.object
  ->Option.flatMap(d => d->Dict.get("pageInfo"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.flatMap(d => d->Dict.get("hasNextPage"))
  ->Option.flatMap(JSON.Decode.bool)
  ->Option.getOr(false)

describe("EventHistoryResolvers_GraphQL — position ordering", () => {
  testSync("orders positions numerically, not lexically", () => {
    // The regression this test exists for: as strings, "10" < "9", so a
    // lexical sort silently reorders every log that passes nine events and
    // cursor pages then skip or duplicate.
    let records = [
      rec_(~position="10", ()),
      rec_(~position="9", ()),
      rec_(~position="2", ()),
      rec_(~position="11", ()),
    ]
    let page = EH.paginate(~records, ~args=args())
    expect(page->positionsOf)->toEqual(["2", "9", "10", "11"])
  })

  testSync("a cursor bound crossing a digit boundary skips nothing", () => {
    let records = Array.make(~length=12, 0)->Array.mapWithIndex((_, i) =>
      rec_(~position=i->Int.toString, ())
    )
    // Page 1 ends at position 9; page 2 must start at 10, not at 1.
    let page1 = EH.paginate(~records, ~args=args(~first=10, ()))
    expect(page1->positionsOf->Array.length)->toBe(10)
    expect(page1->hasNextPageOf)->toBe(true)
    let cursor = page1->endCursorOf->Option.getOr("")
    let page2 = EH.paginate(~records, ~args=args(~first=10, ~after=cursor, ()))
    expect(page2->positionsOf)->toEqual(["10", "11"])
  })
})

describe("EventHistoryResolvers_GraphQL — filtering", () => {
  let records = [
    rec_(~position="1", ~eventType="OrderPlaced", ~tags=[tag("orderId", "o-1")], ~user="alice", ~time="2026-01-01T00:00:00Z", ()),
    rec_(~position="2", ~eventType="OrderShipped", ~tags=[tag("orderId", "o-1")], ~user="bob", ~time="2026-01-05T00:00:00Z", ()),
    rec_(~position="3", ~eventType="OrderPlaced", ~tags=[tag("orderId", "o-2")], ~user="alice", ~time="2026-01-09T00:00:00Z", ()),
  ]
  let filtered = f => records->Array.filter(r => EH.matchesFilter(r, f))->Array.map(r => r.position)

  testSync("entityId matches any tag value", () => {
    expect(filtered({entityId: "o-1"}))->toEqual(["1", "2"])
  })

  testSync("tagKey + tagValue is the precise form", () => {
    expect(filtered({tagKey: "orderId", tagValue: "o-2"}))->toEqual(["3"])
    // A tag key that no event carries matches nothing, rather than falling
    // back to "everything".
    expect(filtered({tagKey: "customerId", tagValue: "o-1"}))->toEqual([])
  })

  testSync("eventTypes narrows to the listed constructors", () => {
    expect(filtered({eventTypes: ["OrderShipped"]}))->toEqual(["2"])
  })

  testSync("user filters on the envelope actor", () => {
    expect(filtered({user: "alice"}))->toEqual(["1", "3"])
  })

  testSync("time range is inclusive on both bounds", () => {
    expect(filtered({timeFrom: "2026-01-05T00:00:00Z"}))->toEqual(["2", "3"])
    expect(filtered({timeTo: "2026-01-05T00:00:00Z"}))->toEqual(["1", "2"])
    expect(
      filtered({timeFrom: "2026-01-05T00:00:00Z", timeTo: "2026-01-05T00:00:00Z"}),
    )->toEqual(["2"])
  })

  testSync("an empty filter keeps everything", () => {
    expect(filtered({}))->toEqual(["1", "2", "3"])
  })

  testSync("filters compose (AND, not OR)", () => {
    expect(filtered({entityId: "o-1", user: "alice"}))->toEqual(["1"])
  })
})

describe("EventHistoryResolvers_GraphQL — argument decoding", () => {
  testSync("reads every filter field off the GraphQL args", () => {
    let raw = JSON.Encode.object(
      Dict.fromArray([
        (
          "filter",
          JSON.Encode.object(
            Dict.fromArray([
              ("entityId", JSON.Encode.string("o-1")),
              ("tagKey", JSON.Encode.string("orderId")),
              ("tagValue", JSON.Encode.string("o-1")),
              (
                "eventTypes",
                [JSON.Encode.string("OrderPlaced")]->JSON.Encode.array,
              ),
              ("user", JSON.Encode.string("alice")),
              ("timeFrom", JSON.Encode.string("2026-01-01")),
              ("timeTo", JSON.Encode.string("2026-02-01")),
            ]),
          ),
        ),
      ]),
    )
    let f = EH.readFilter(raw)
    expect(f.entityId)->toEqual(Some("o-1"))
    expect(f.tagKey)->toEqual(Some("orderId"))
    expect(f.eventTypes)->toEqual(Some(["OrderPlaced"]))
    expect(f.user)->toEqual(Some("alice"))
    expect(f.timeFrom)->toEqual(Some("2026-01-01"))
    expect(f.timeTo)->toEqual(Some("2026-02-01"))
  })

  testSync("absent filter decodes to the everything filter", () => {
    let f = EH.readFilter(JSON.Encode.object(Dict.make()))
    expect(f.entityId)->toEqual(None)
    expect(f.eventTypes)->toEqual(None)
  })
})

describe("EventHistoryResolvers_GraphQL — pagination", () => {
  let records = Array.make(~length=5, 0)->Array.mapWithIndex((_, i) =>
    rec_(~position=(i + 1)->Int.toString, ())
  )

  testSync("forward paging reports hasNextPage until exhausted", () => {
    let page = EH.paginate(~records, ~args=args(~first=2, ()))
    expect(page->positionsOf)->toEqual(["1", "2"])
    expect(page->hasNextPageOf)->toBe(true)
    let last = EH.paginate(~records, ~args=args(~first=10, ()))
    expect(last->hasNextPageOf)->toBe(false)
  })

  testSync("backward paging takes the tail", () => {
    let page = EH.paginate(~records, ~args=args(~last=2, ()))
    expect(page->positionsOf)->toEqual(["4", "5"])
  })

  testSync("no records yields an empty connection, not a crash", () => {
    let page = EH.paginate(~records=[], ~args=args())
    expect(page->positionsOf)->toEqual([])
    expect(page->hasNextPageOf)->toBe(false)
  })
})
