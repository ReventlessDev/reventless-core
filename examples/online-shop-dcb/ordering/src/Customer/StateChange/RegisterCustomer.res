// RegisterCustomer StateChangeSlice.
// Handles the RegisterCustomer command; rejects duplicate registration.
@@reventless.spec

@schema
type consumedEvent =
  | CustomerRegistered

@schema
type command =
  | RegisterCustomer({customerId: string, email: string, address: string})

@schema
type error = CustomerAlreadyRegistered

@schema
type event =
  | CustomerRegistered({
      customerId: string,
      email: string,
      address: string,
    })
