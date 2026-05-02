// Customers read model specification.
// Query-side state for registered customers.

@@reventless.spec

@schema
type state = {
  @displayName email: string,
  address: string,
  deactivated: bool,
}
