// Orders read model specification.
// Query-side state for customer orders.

@@reventless.spec

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled
  | Refunded

@schema
type state = {
  customerId: string,
  productIds: array<string>,
  // No annotation: the field name is the declaration. `@lifecycle` exists for
  // records whose lifecycle field is honestly called something else.
  lifecycle: lifecycle,
}

