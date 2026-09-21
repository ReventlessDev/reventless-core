// The checks that make adopting identities complete once a plugin starts: a
// field named for one identity but typed as another, an id left as a plain string
// beside its identity, and a slice partitioned by another chapter's identity.

open JestGlobals

module OrderId = Id.Make({
  let key = "orderId"
})
module CustomerId = Id.Make({
  let key = "customerId"
})

let slice = (~name, ~moduleUrl=?, event: S.t<'a>): DcbTag.sliceSchemas => {
  name,
  commandSchema: S.unit->S.castToUnknown,
  consumedEventSchema: S.unit->S.castToUnknown,
  eventSchema: event->S.castToUnknown,
  ?moduleUrl,
}

let messagesOf = slices => IdentityCheck.check(slices)->Array.map(f => f.message)

let placed = slice(
  ~name="PlaceOrder",
  S.schema(s => {"orderId": s.matches(OrderId.schema), "buyer": s.matches(CustomerId.schema)}),
)

describe("IdentityCheck.check", () => {
  testSync("a plugin that types nothing is never reported", () =>
    expect(
      messagesOf([slice(~name="S", S.schema(s => {"orderId": s.matches(S.string)}))]),
    )->toEqual([])
  )

  testSync("a consistent plugin reports nothing", () => expect(messagesOf([placed]))->toEqual([]))

  testSync("a field named for one identity and typed as another is reported", () => {
    let mixed = slice(~name="ShipOrder", S.schema(s => {"orderId": s.matches(CustomerId.schema)}))
    let messages = messagesOf([placed, mixed])
    expect(messages->Array.some(m => m->String.includes("typed as a customerId")))->toBe(true)
  })

  testSync("a role name that is no identity of its own is fine", () => {
    let role = slice(~name="Refer", S.schema(s => {"referrerId": s.matches(CustomerId.schema)}))
    expect(messagesOf([placed, role]))->toEqual([])
  })

  testSync("an untyped id beside its identity is reported", () => {
    let untyped = slice(~name="CancelOrder", S.schema(s => {"orderId": s.matches(S.string)}))
    let messages = messagesOf([placed, untyped])
    expect(messages->Array.some(m => m->String.includes("orderId is a plain string")))->toBe(true)
  })
})

describe("IdentityCheck.checkChapters", () => {
  let underOrder = slice(
    ~name="PlaceOrder",
    ~moduleUrl="@x/ordering/src/Order/StateChange/PlaceOrder.res.mjs",
    S.schema(s => {"orderId": s.matches(OrderId.schema)}),
  )

  testSync("a slice in its identity's chapter is fine", () =>
    expect(
      IdentityCheck.checkChapters(
        ~identityChapters=Dict.fromArray([("orderId", "Order")]),
        ~partitionBySlice=Dict.fromArray([("PlaceOrder", "orderId")]),
        [underOrder],
      ),
    )->toEqual([])
  )

  testSync("a slice partitioned by another chapter's identity is reported", () => {
    let findings = IdentityCheck.checkChapters(
      ~identityChapters=Dict.fromArray([("orderId", "Customer")]),
      ~partitionBySlice=Dict.fromArray([("PlaceOrder", "orderId")]),
      [underOrder],
    )
    expect(findings->Array.map(f => f.sliceName))->toEqual(["PlaceOrder"])
  })

  testSync("an identity declared in another package is not checked", () =>
    expect(
      IdentityCheck.checkChapters(
        ~identityChapters=Dict.make(),
        ~partitionBySlice=Dict.fromArray([("PlaceOrder", "orderId")]),
        [underOrder],
      ),
    )->toEqual([])
  )
})
