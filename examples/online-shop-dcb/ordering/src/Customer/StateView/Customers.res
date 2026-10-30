// Customers StateViewSlice.
// Projects customer events from the shared ordering event log into a Customers read model.
@@reventless.spec

// Rows are keyed by this identity.
module Id = CustomerId

@schema
type state = {
  customerId: CustomerId.t,
  @displayName email: string,
  address: string,
  deactivated: bool,
}

@schema
type consumedEvent =
  | CustomerRegistered({customerId: CustomerId.t, @pii email: string, @pii address: string})
  | EmailChanged({customerId: CustomerId.t, @pii email: string})
  | AddressChanged({customerId: CustomerId.t, @pii address: string})
  | CustomerDeactivated({customerId: CustomerId.t})
