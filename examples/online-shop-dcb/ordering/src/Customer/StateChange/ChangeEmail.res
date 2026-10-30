// ChangeEmail StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when email is unchanged.
@@reventless.spec

@schema
type consumedEvent =
  | CustomerRegistered({@pii email: string})
  | EmailChanged({@pii email: string})
  | CustomerDeactivated

@schema
type command = ChangeEmail({customerId: CustomerId.t, @pii("customerId") email: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

@schema
type event = EmailChanged({customerId: CustomerId.t, @pii("customerId") email: string})
