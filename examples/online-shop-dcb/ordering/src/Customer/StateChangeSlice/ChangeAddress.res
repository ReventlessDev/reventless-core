// ChangeAddress StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when address is unchanged.
@@reventless.spec

@schema
type consumedEvent =
  | CustomerRegistered({address: string})
  | AddressChanged({address: string})
  | CustomerDeactivated

@schema
type command = ChangeAddress({customerId: string, address: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

@schema
type event = AddressChanged({customerId: string, address: string})
