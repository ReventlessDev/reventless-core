@@reventless.decision

type state = {exists: bool, deactivated: bool, currentEmail: string}

let initialState = {exists: false, deactivated: false, currentEmail: ""}

let evolve = (state, event) =>
  switch event {
  // An erased address matches no address presented later.
  | CustomerRegistered({email}) => {
      exists: true,
      deactivated: false,
      currentEmail: email->Reventless.Pii.getOr(""),
    }
  | EmailChanged({email}) => {...state, currentEmail: email->Reventless.Pii.getOr("")}
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
      Ok([EmailChanged({customerId, email: Value(email)})])
    }
  }
