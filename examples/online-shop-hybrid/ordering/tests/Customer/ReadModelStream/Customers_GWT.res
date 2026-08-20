// `MultiSourceProjection_GWT.Make` is single-source, so one GWT module per source
// mapping. At runtime the two merge on `customerId`; here each is tested alone.

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
      Customers.customerId: "id",
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Active,
      orderCount: 0,
    })
  )

  CustomerGwt.test("EmailUpdated updates the email", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.EmailUpdated({email: "alice2@x.y"}))
    ->CustomerGwt.thenState({
      Customers.customerId: "id",
      email: "alice2@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Active,
      orderCount: 0,
    })
  )

  CustomerGwt.test("AddressUpdated updates the address", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.AddressUpdated({address: "789 Pine"}))
    ->CustomerGwt.thenState({
      Customers.customerId: "id",
      email: "alice@x.y",
      address: "789 Pine",
      geolocation: Pending({requestedFor: "789 Pine"}),
      accountStatus: Active,
      orderCount: 0,
    })
  )

  CustomerGwt.test("LocationSet fills the declared point", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.LocationSet({location: {lat: 51.2093, lng: 3.2247}, resolvedFrom: "123 Main"}))
    ->CustomerGwt.thenState({
      Customers.customerId: "id",
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Located({point: {lat: 51.2093, lng: 3.2247}}),
      accountStatus: Active,
      orderCount: 0,
    })
  )

  CustomerGwt.test("Deactivated sets deactivated flag", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.Deactivated)
    ->CustomerGwt.thenState({
      Customers.customerId: "id",
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Deactivated,
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
      {
        Customers.customerId: "c1",
        email: "",
        address: "",
        geolocation: Pending({requestedFor: ""}),
        accountStatus: Active,
        orderCount: 1,
      },
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
      {
        Customers.customerId: "c1",
        email: "",
        address: "",
        geolocation: Pending({requestedFor: ""}),
        accountStatus: Active,
        orderCount: 2,
      },
    )
  )
})
