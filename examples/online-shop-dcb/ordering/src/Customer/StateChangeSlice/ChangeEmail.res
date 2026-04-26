// ChangeEmail StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when email is unchanged.
@@reventless.spec

@schema
type consumedEvent =
  | CustomerRegistered({email: string})
  | EmailChanged({email: string})
  | CustomerDeactivated

@schema
type command = ChangeEmail({customerId: string, email: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

@schema
type event = EmailChanged({customerId: string, email: string})
