// Orders read model specification.
// Query-side state for customer orders.

@@reventless.spec

module Id = OrderId

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled
  | Refunded

@schema
type state = {
  customerId: CustomerId.t,
  productIds: array<CatalogSpec.ProductId.t>,
  // No annotation: the field name is the declaration. `@lifecycle` exists for
  // records whose lifecycle field is honestly called something else.
  lifecycle: lifecycle,
}
