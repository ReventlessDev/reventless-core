@@reventless.behavior

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | CustomerRegistered => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | RegisterCustomer({customerId, email, address}) =>
    if state.exists {
      Error(CustomerAlreadyRegistered)
    } else {
      Ok([CustomerRegistered({customerId, email, address})])
    }
  }
