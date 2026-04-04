// RegisterCustomer StateChangeSlice.
// Handles the RegisterCustomer command; rejects duplicate registration.
@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool}

let initialState = {exists: false}

@schema
type consumedEvent =
  | CustomerRegistered

let evolve = (_state, event) =>
  switch event {
  | CustomerRegistered => {exists: true}
  }

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

let decide = (state, command) =>
  switch command {
  | RegisterCustomer({customerId, email, address}) =>
    if state.exists {
      Error(CustomerAlreadyRegistered)
    } else {
      Ok([CustomerRegistered({customerId, email, address})])
    }
  }
