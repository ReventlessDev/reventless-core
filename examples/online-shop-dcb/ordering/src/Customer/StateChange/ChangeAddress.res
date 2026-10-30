// ChangeAddress StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when address is unchanged.
@@reventless.spec

@schema
type consumedEvent =
  | CustomerRegistered({@pii address: string})
  | AddressChanged({@pii address: string})
  | CustomerDeactivated

@schema
type command = ChangeAddress({customerId: CustomerId.t, @pii("customerId") address: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

@schema
type event = AddressChanged({customerId: CustomerId.t, @pii("customerId") address: string})
