// Customers StateViewSlice.
// Projects customer events from the shared ordering event log into a Customers read model.
@@reventless.spec

@schema
type state = {customerId: string, email: string, address: string, deactivated: bool}

@schema
type consumedEvent =
  | CustomerRegistered({customerId: string, email: string, address: string})
  | EmailChanged({customerId: string, email: string})
  | AddressChanged({customerId: string, address: string})
  | CustomerDeactivated({customerId: string})
