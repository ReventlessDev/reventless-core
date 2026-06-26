// Customers read model specification.
// Query-side state for registered customers. This is a **mixed-source** read
// model: the customer profile fields come from the Customer aggregate, while
// `orderCount` is fed by the Ordering DCB log's `OrderPlaced` events (keyed by
// `customerId`). See `Customers_Projections.res` for the two source mappings.

@@reventless.spec

@schema
type state = {
  @displayName email: string,
  address: string,
  deactivated: bool,
  orderCount: int,
}
