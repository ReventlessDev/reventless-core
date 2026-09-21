// A typed id finds the view that lists it without an `@ref`, whenever exactly one
// view is keyed by its identity. Where the type cannot decide, it says so rather
// than guessing: which list a reference means is a product decision.

open JestGlobals

module ProductId = Reventless.Id.Make({
  let key = "productId"
})
module CustomerId = Reventless.Id.Make({
  let key = "customerId"
})

let refsOf = (~viewsByKey, ~minted=?, schema: S.t<'a>) => {
  let reports = []
  let identityViews: Plugin_Structure.identityViews = {
    viewsByKey: Dict.fromArray(viewsByKey),
    viewNames: viewsByKey->Array.flatMap(((_, views)) => views),
    report: message => reports->Array.push(message),
  }
  let properties = switch schema->S.castToUnknown {
  | Object({properties}) => properties
  | _ => Dict.make()
  }
  let refs =
    Plugin_Structure.extractReferences(~identityViews, ~minted?, properties)->Array.map(r => (
      r.fieldName,
      r.entity,
    ))
  (refs, reports)
}

let order = S.schema(s =>
  {
    "buyer": s.matches(CustomerId.schema),
    "productIds": s.matches(S.array(ProductId.schema)),
    "note": s.matches(S.string),
  }
)

describe("a reference derived from the type", () => {
  testSync("exactly one view keyed by the identity is the reference", () => {
    let (refs, reports) = refsOf(
      ~viewsByKey=[("customerId", ["Customers"]), ("productId", ["AvailableProducts"])],
      order,
    )
    expect(refs)->toEqual([("buyer", "Customers"), ("productIds", "AvailableProducts")])
    expect(reports)->toEqual([])
  })

  testSync("several views keyed by it ask for @ref instead of guessing", () => {
    let (refs, reports) = refsOf(
      ~viewsByKey=[("customerId", ["Customers"]), ("productId", ["Products", "ProductDemand"])],
      order,
    )
    expect(refs)->toEqual([("buyer", "Customers")])
    expect(reports->Array.some(r => r->String.includes("Products and ProductDemand")))->toBe(true)
  })

  testSync("no view keyed by it is reported", () => {
    let (refs, reports) = refsOf(~viewsByKey=[("productId", ["AvailableProducts"])], order)
    expect(refs)->toEqual([("productIds", "AvailableProducts")])
    expect(reports->Array.some(r => r->String.includes("no view in this plugin")))->toBe(true)
  })

  // A create form mints this id; a list of the rows that already exist is the
  // wrong control for it.
  testSync("the id a creating command mints references nothing", () => {
    let (refs, reports) = refsOf(
      ~viewsByKey=[("customerId", ["Customers"]), ("productId", ["AvailableProducts"])],
      ~minted="buyer",
      order,
    )
    expect((refs, reports))->toEqual(([("productIds", "AvailableProducts")], []))
  })

  testSync("an untyped field is left to its name, as before", () => {
    let (refs, reports) = refsOf(
      ~viewsByKey=[("customerId", ["Customers"])],
      S.schema(s => {"customerId": s.matches(S.string)}),
    )
    expect((refs, reports))->toEqual(([], []))
  })
})

describe("a declared @ref on a typed id", () => {
  let referenced = S.schema(s =>
    {"buyer": s.matches(CustomerId.schema->Reventless.Reference.mark("Products"))}
  )

  testSync("is kept, and checked against the views keyed by the identity", () => {
    let (refs, reports) = refsOf(
      ~viewsByKey=[("customerId", ["Customers"]), ("productId", ["Products"])],
      referenced,
    )
    expect(refs)->toEqual([("buyer", "Products")])
    expect(reports->Array.some(r => r->String.includes("not keyed by it")))->toBe(true)
  })

  testSync("naming a view keyed by the identity is fine", () => {
    let chosen = S.schema(
      s => {"buyer": s.matches(CustomerId.schema->Reventless.Reference.mark("Customers"))},
    )
    let (refs, reports) = refsOf(
      ~viewsByKey=[("customerId", ["Customers", "VipCustomers"])],
      chosen,
    )
    expect((refs, reports))->toEqual(([("buyer", "Customers")], []))
  })

  testSync("stands on a minted id: only the derived one steps aside", () => {
    let chosen = S.schema(
      s => {"buyer": s.matches(CustomerId.schema->Reventless.Reference.mark("Customers"))},
    )
    let (refs, _) = refsOf(~viewsByKey=[("customerId", ["Customers"])], ~minted="buyer", chosen)
    expect(refs)->toEqual([("buyer", "Customers")])
  })
})
