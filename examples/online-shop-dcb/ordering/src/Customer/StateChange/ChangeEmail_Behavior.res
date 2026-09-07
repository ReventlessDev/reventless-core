@@reventless.behavior

type state = {exists: bool, deactivated: bool, currentEmail: string}

let initialState = {exists: false, deactivated: false, currentEmail: ""}

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered({email}) => {exists: true, deactivated: false, currentEmail: email}
  | EmailChanged({email}) => {...state, currentEmail: email}
  | CustomerDeactivated => {...state, deactivated: true}
  }

let decide = (state, command) =>
  switch command {
  | ChangeEmail({customerId, email}) =>
    if !state.exists {
      Error(CustomerNotFound)
    } else if state.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if email == state.currentEmail {
      Ok([]) // idempotent — email unchanged
    } else {
      Ok([EmailChanged({customerId, email})])
    }
  }
