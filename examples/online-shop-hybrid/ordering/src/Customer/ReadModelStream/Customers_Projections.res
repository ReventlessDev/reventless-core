// Customer projection mappings — a single read model fed by TWO sources:
//
//   1. the **Customer aggregate** (profile: email, address, deactivated), and
//   2. the **Ordering DCB EventLog** (`orderCount`, from `OrderPlaced` events).
//
// This is the canonical mixed **aggregate + DCB** read model: an aggregate's
// per-instance state correlated with DCB events that reference it by a shared
// key (`customerId`). Both mappings write to the same row id, so the framework
// merges them into one `Customers` record.
//
// The DCB source's `name` MUST equal `<pluginName>DcbEventLog`
// ("OrderingDcbEventLog") — the key under which `Plugin_Builder` registers the
// ordering plugin's DCB EventTopic AND the `meta.service` DcbEventLog stamps on
// every published event.
//
// Both mappings use `UpdateWithDefault` so the merge is order-independent: an
// `OrderPlaced` that arrives before its customer's `Registered` still creates a
// row (and vice-versa), and neither source clobbers the other's fields.

@@reventless.mappings

// ─────────────────────────────────────────────────────────────
// DCB source view — Order-side events (only what this read model needs)
// ─────────────────────────────────────────────────────────────

module OrderEvents = {
  let name = "OrderingDcbEventLog"

  @schema
  type event = OrderPlaced({orderId: string, customerId: string})
}

// ─────────────────────────────────────────────────────────────
// Source 1 — Customer aggregate (profile)
// ─────────────────────────────────────────────────────────────

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
            Customers.email: email,
            address,
            location: None,
            locationStatus: Pending,
            locationNote: None,
            deactivated: false,
            orderCount: 0,
          },
          state => {...state, email, address, deactivated: false},
        )
      | EmailUpdated({email}) => Update(id, state => {...state, email})
      // A new address invalidates the pin: back to Pending until the geocoding
      // slice answers for the new one. Leaving the old point on the row would
      // show an address and a marker that disagree, with nothing saying so.
      | AddressUpdated({address}) =>
        Update(id, state => {
          ...state,
          address,
          location: None,
          locationStatus: Pending,
          locationNote: None,
        })
      | LocationSet({location}) =>
        Update(id, state => {
          ...state,
          location: Some(location),
          locationStatus: Located,
          locationNote: None,
        })
      // Both halves in one event — the client supplied the pair, so the row is
      // Located immediately and no geocode is owed.
      | AddressLocated({address, location}) =>
        Update(id, state => {
          ...state,
          address,
          location: Some(location),
          locationStatus: Located,
          locationNote: None,
        })
      | AddressUnresolvable({reason}) =>
        Update(id, state => {
          ...state,
          location: None,
          locationStatus: Unresolvable,
          locationNote: Some(reason),
        })
      | Deactivated => Update(id, state => {...state, deactivated: true})
      }
  },
)

// ─────────────────────────────────────────────────────────────
// Source 2 — Ordering DCB EventLog (order count, keyed by customerId)
// ─────────────────────────────────────────────────────────────

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
            Customers.email: "",
            address: "",
            location: None,
            locationStatus: Pending,
            locationNote: None,
            deactivated: false,
            orderCount: 1,
          },
          state => {...state, orderCount: state.orderCount + 1},
        )
      }
  },
)

let mappings: array<module(Mapping)> = [module(CustomerMapping), module(CustomerOrdersMapping)]
