// Multi-source ReadModel: one `_GWT` instance per source mapping. The
// `MultiSourceProjection_GWT.Make` functor is single-source — wire one GWT
// module per source view and let each describe its own slice of behaviour.
// (At runtime the two mappings merge into one row keyed by `customerId`; each
// module here exercises its source in isolation.)

module CustomerGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  Customers_Projections.CustomerMapping,
)
module OrderGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  Customers_Projections.CustomerOrdersMapping,
)

CustomerGwt.describe("Customers ReadModel ← Customer aggregate", () => {
  CustomerGwt.test("Registered sets initial read model state", () =>
    CustomerGwt.givenEvents([])
    ->CustomerGwt.whenEvent(Customer.Registered({email: "alice@x.y", address: "123 Main"}))
    ->CustomerGwt.thenState({
      Customers.email: "alice@x.y",
      address: "123 Main",
      location: None,
      deactivated: false,
      orderCount: 0,
    })
  )

  CustomerGwt.test("EmailUpdated updates the email", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.EmailUpdated({email: "alice2@x.y"}))
    ->CustomerGwt.thenState({
      Customers.email: "alice2@x.y",
      address: "123 Main",
      location: None,
      deactivated: false,
      orderCount: 0,
    })
  )

  CustomerGwt.test("AddressUpdated updates the address", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.AddressUpdated({address: "789 Pine"}))
    ->CustomerGwt.thenState({
      Customers.email: "alice@x.y",
      address: "789 Pine",
      location: None,
      deactivated: false,
      orderCount: 0,
    })
  )

  CustomerGwt.test("LocationSet fills the declared point", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.LocationSet({location: {lat: 51.2093, lng: 3.2247}}))
    ->CustomerGwt.thenState({
      Customers.email: "alice@x.y",
      address: "123 Main",
      location: Some({lat: 51.2093, lng: 3.2247}),
      deactivated: false,
      orderCount: 0,
    })
  )

  CustomerGwt.test("Deactivated sets deactivated flag", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.Deactivated)
    ->CustomerGwt.thenState({
      Customers.email: "alice@x.y",
      address: "123 Main",
      location: None,
      deactivated: true,
      orderCount: 0,
    })
  )
})

OrderGwt.describe("Customers ReadModel ← Ordering DCB log", () => {
  OrderGwt.test("OrderPlaced creates a row and counts the placement", () =>
    OrderGwt.givenEvents([])
    ->OrderGwt.whenEvent(
      Customers_Projections.OrderEvents.OrderPlaced({orderId: "o1", customerId: "c1"}),
    )
    ->OrderGwt.thenStateWithId(
      "c1",
      {Customers.email: "", address: "", location: None, deactivated: false, orderCount: 1},
    )
  )

  OrderGwt.test("a second OrderPlaced increments orderCount", () =>
    OrderGwt.givenEvents([
      Customers_Projections.OrderEvents.OrderPlaced({orderId: "o1", customerId: "c1"}),
    ])
    ->OrderGwt.whenEvent(
      Customers_Projections.OrderEvents.OrderPlaced({orderId: "o2", customerId: "c1"}),
    )
    ->OrderGwt.thenStateWithId(
      "c1",
      {Customers.email: "", address: "", location: None, deactivated: false, orderCount: 2},
    )
  )
})
