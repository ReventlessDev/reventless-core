// DeactivateCustomer StateChangeSlice.
// Requires customer to exist; idempotent if already deactivated.
@@reventless.spec

@schema
type consumedEvent =
  | CustomerRegistered
  | CustomerDeactivated

@schema
type command = DeactivateCustomer({customerId: string})

@schema
type error = CustomerNotFound

@schema
type event = CustomerDeactivated({customerId: string})
