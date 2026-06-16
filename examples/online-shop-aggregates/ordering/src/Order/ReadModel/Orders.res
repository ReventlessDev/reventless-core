// Orders read model specification.
// Query-side state for customer orders.

@@reventless.spec

@schema
type status =
  | Placed
  | Shipped
  | Cancelled
  | Refunded

@schema
type state = {
  customerId: string,
  productIds: array<string>,
  @status status: status,
}

