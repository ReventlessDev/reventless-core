open OrderingExamples

// `MultiSourceProjection_GWT.Make` is single-source, so one GWT module per source
// mapping. At runtime the two merge on `customerId`; here each is tested alone.

module CustomerGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  Customers_Projections.CustomerMapping,
)
module OrderGwt = ReventlessGwt.MultiSourceProjection_GWT.Make(
  Customers_Projections.CustomerOrdersMapping,
)

CustomerGwt.describe("Customers ReadModel ← Customer aggregate", () => {
  // scenario-id: 9431f1b4-c0d9-4701-a775-868303d22a44
  CustomerGwt.test("Registered sets initial read model state", () =>
    CustomerGwt.givenEvents([])
    ->CustomerGwt.whenEvent(Customer.Registered({email: "alice@x.y", address: "123 Main"}))
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Active,
      emailVerified: false,
      orderCount: 0,
    })
  )

  // scenario-id: 613b1eac-aa5c-45fd-b850-5f1277edb982
  CustomerGwt.test("EmailUpdated updates the email", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.EmailUpdated({email: "alice2@x.y"}))
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice2@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Active,
      emailVerified: false,
      orderCount: 0,
    })
  )

  // scenario-id: 51912b68-3f7a-4e93-8638-1789c713cbbe
  CustomerGwt.test("EmailVerified marks the address proven", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.EmailVerified({email: "alice@x.y"}))
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Active,
      emailVerified: true,
      orderCount: 0,
    })
  )

  // 🚨 The row must not carry the badge across a change. Keeping it would show an
  // address as proven that nobody has proven — the read model's half of the same
  // guard the aggregate applies.
  // scenario-id: e0c8a59a-2983-41e6-8bd9-8772d75bc319
  CustomerGwt.test("EmailUpdated drops the proof along with the address", () =>
    CustomerGwt.givenEvents([
      Customer.Registered({email: "alice@x.y", address: "123 Main"}),
      Customer.EmailVerified({email: "alice@x.y"}),
    ])
    ->CustomerGwt.whenEvent(Customer.EmailUpdated({email: "alice2@x.y"}))
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice2@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Active,
      emailVerified: false,
      orderCount: 0,
    })
  )

  // scenario-id: ebe80da0-b636-4a35-8545-ff397b25c7cd
  CustomerGwt.test("AddressUpdated updates the address", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.AddressUpdated({address: "789 Pine"}))
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice@x.y",
      address: "789 Pine",
      geolocation: Pending({requestedFor: "789 Pine"}),
      accountStatus: Active,
      emailVerified: false,
      orderCount: 0,
    })
  )

  // scenario-id: 0968023d-2cc1-493a-bf83-07ee42ab1438
  CustomerGwt.test("LocationSet fills the declared point", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(
      Customer.LocationSet({location: {lat: 51.2093, lng: 3.2247}, resolvedFrom: "123 Main"}),
    )
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Located({point: {lat: 51.2093, lng: 3.2247}}),
      accountStatus: Active,
      emailVerified: false,
      orderCount: 0,
    })
  )

  // scenario-id: aefc51f3-c008-4eca-b90e-995443e712e6
  CustomerGwt.test("Deactivated sets deactivated flag", () =>
    CustomerGwt.givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->CustomerGwt.whenEvent(Customer.Deactivated)
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Deactivated,
      emailVerified: false,
      orderCount: 0,
    })
  )

  // The way back. Deactivation is not deletion, so the profile that comes back is
  // the profile that went in — and the row lands in Active rather than being
  // registered a second time.
  // scenario-id: 404f735f-3d33-4b1a-8065-d93531bf887b
  CustomerGwt.test("Reactivated returns the row to active", () =>
    CustomerGwt.givenEvents([
      Customer.Registered({email: "alice@x.y", address: "123 Main"}),
      Customer.Deactivated,
    ])
    ->CustomerGwt.whenEvent(Customer.Reactivated)
    ->CustomerGwt.thenState({
      Customers.customerId: id,
      email: "alice@x.y",
      address: "123 Main",
      geolocation: Pending({requestedFor: "123 Main"}),
      accountStatus: Active,
      emailVerified: false,
      orderCount: 0,
    })
  )
})

OrderGwt.describe("Customers ReadModel ← Ordering DCB log", () => {
  // scenario-id: 64b84fe3-9d1e-4d35-9d98-c02a5f7af22a
  OrderGwt.test("OrderPlaced creates a row and counts the placement", () =>
    OrderGwt.givenEvents([])
    ->OrderGwt.whenEvent(
      Customers_Projections.OrderEvents.OrderPlaced({orderId: o1, customerId: c1}),
    )
    ->OrderGwt.thenStateWithId(
      "c1",
      {
        Customers.customerId: c1,
        email: "",
        address: "",
        geolocation: Pending({requestedFor: ""}),
        accountStatus: Active,
        emailVerified: false,
        orderCount: 1,
      },
    )
  )

  // scenario-id: 0f9f7813-327a-4e83-9965-03a7367dc219
  OrderGwt.test("a second OrderPlaced increments orderCount", () =>
    OrderGwt.givenEvents([
      Customers_Projections.OrderEvents.OrderPlaced({orderId: o1, customerId: c1}),
    ])
    ->OrderGwt.whenEvent(
      Customers_Projections.OrderEvents.OrderPlaced({orderId: o2, customerId: c1}),
    )
    ->OrderGwt.thenStateWithId(
      "c1",
      {
        Customers.customerId: c1,
        email: "",
        address: "",
        geolocation: Pending({requestedFor: ""}),
        accountStatus: Active,
        emailVerified: false,
        orderCount: 2,
      },
    )
  )
})
