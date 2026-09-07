@@reventless.behavior

type state = {exists: bool, deactivated: bool}

let initialState = {exists: false, deactivated: false}

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered => {exists: true, deactivated: false}
  | CustomerDeactivated => {...state, deactivated: true}
  }

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
