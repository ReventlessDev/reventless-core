// One read model fed by two sources — the Customer aggregate (profile) and the
// Ordering DCB EventLog (`orderCount`) — merged on `customerId`.
//
// The DCB source's `name` MUST equal `<pluginName>DcbEventLog`: it is both the key
// `Plugin_Builder` registers the EventTopic under and the `meta.service` stamped
// on every published event.
//
// Both use `UpdateWithDefault`, so the merge is order-independent.

@@reventless.mappings

// DCB source view — only the Order-side events this read model needs.

module OrderEvents = {
  let name = "OrderingDcbEventLog"

  @schema
  type event = OrderPlaced({orderId: string, customerId: string})
}

// Source 1 — Customer aggregate (profile)

module CustomerMapping = Mapping.Make(
  Customer,
  Customers,
  {
    open Customer
    let project = ({event, id, _}) =>
      switch event {
      | Registered({email, address}) =>
        UpdateWithDefault(
          id,
          {
            Customers.customerId: id,
            email,
            address,
            geolocation: Pending({requestedFor: address}),
            accountStatus: Active,
            orderCount: 0,
          },
          state => {...state, email, address, accountStatus: Active},
        )
      | EmailUpdated({email}) => Update(id, state => {...state, email})
      // A new address invalidates the pin: back to Pending for the new one.
      | AddressUpdated({address}) =>
        Update(id, state => {...state, address, geolocation: Pending({requestedFor: address})})
      | LocationSet({location}) =>
        Update(id, state => {...state, geolocation: Located({point: location})})
      // The client supplied the pair, so no geocode is owed.
      | AddressLocated({address, location}) =>
        Update(id, state => {...state, address, geolocation: Located({point: location})})
      | AddressUnresolvable({reason: why}) =>
        Update(id, state => {...state, geolocation: Unresolvable({reason: why})})
      | Deactivated => Update(id, state => {...state, accountStatus: Deactivated})
      // The aggregate held the profile throughout, so nothing is rebuilt here.
      | Reactivated => Update(id, state => {...state, accountStatus: Active})
      }
  },
)

// Source 2 — Ordering DCB EventLog (order count, keyed by customerId)

module CustomerOrdersMapping = Mapping.Make(
  OrderEvents,
  Customers,
  {
    open OrderEvents
    let project = ({event, _}) =>
      switch event {
      | OrderPlaced({customerId}) =>
        UpdateWithDefault(
          customerId,
          {
            Customers.customerId: customerId,
            email: "",
            address: "",
            // No address from this side; `Registered` fills it in when it arrives.
            geolocation: Pending({requestedFor: ""}),
            accountStatus: Active,
            orderCount: 1,
          },
          state => {...state, orderCount: state.orderCount + 1},
        )
      }
  },
)

let mappings: array<module(Mapping)> = [module(CustomerMapping), module(CustomerOrdersMapping)]
