// Customers read model specification.
// Query-side state for registered customers. This is a **mixed-source** read
// model: the customer profile fields come from the Customer aggregate, while
// `orderCount` is fed by the Ordering DCB log's `OrderPlaced` events (keyed by
// `customerId`). See `Customers_Projections.res` for the two source mappings.

@@reventless.spec

// `lat`/`lng` are a numeric coordinate pair, so the generated read-model view
// offers a map display that drops a pin per customer. They are fed by the
// Customer aggregate's `LocationSet` event (see `Customers_Projections.res`).
@schema
type state = {
  @displayName email: string,
  address: string,
  lat: float,
  lng: float,
  deactivated: bool,
  orderCount: int,
}
