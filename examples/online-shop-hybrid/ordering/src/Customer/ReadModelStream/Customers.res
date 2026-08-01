// Customers read model specification.
// Query-side state for registered customers. This is a **mixed-source** read
// model: the customer profile fields come from the Customer aggregate, while
// `orderCount` is fed by the Ordering DCB log's `OrderPlaced` events (keyed by
// `customerId`). See `Customers_Projections.res` for the two source mappings.

@@reventless.spec

// `location` is one declared point, so the generated read-model view offers a
// map display that drops a pin per customer — from the declaration, not from a
// `lat`/`lng` name guess over the numeric fields. It is fed by the Customer
// aggregate's `LocationSet` event (see `Customers_Projections.res`), and it is
// `option` because a customer has no location until that event arrives: the
// `0.0, 0.0` this used to default to is a real coordinate in the Gulf of Guinea,
// so every unlocated customer was pinned there.
@schema
type state = {
  @displayName email: string,
  address: string,
  location: option<Reventless.GeoPoint.t>,
  deactivated: bool,
  orderCount: int,
}
