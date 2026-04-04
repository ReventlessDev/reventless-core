// DeactivateCustomer StateChangeSlice.
// Requires customer to exist; idempotent if already deactivated.
@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool, deactivated: bool}

let initialState = {exists: false, deactivated: false}

@schema
type consumedEvent =
  | CustomerRegistered
  | CustomerDeactivated

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered => {exists: true, deactivated: false}
  | CustomerDeactivated => {...state, deactivated: true}
  }

@schema
type command = DeactivateCustomer({customerId: string})

@schema
type error = CustomerNotFound

@schema
type event = CustomerDeactivated({customerId: string})

let decide = (state, command) =>
  switch command {
  | DeactivateCustomer({customerId: theId}) =>
    if !state.exists {
      Error(CustomerNotFound)
    } else if state.deactivated {
      Ok([]) // idempotent — already deactivated
    } else {
      Ok([CustomerDeactivated({customerId: theId})])
    }
  }
