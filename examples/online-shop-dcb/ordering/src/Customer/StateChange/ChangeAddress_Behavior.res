@@reventless.behavior

type state = {exists: bool, deactivated: bool, currentAddress: string}

let initialState = {exists: false, deactivated: false, currentAddress: ""}

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered({address}) => {
      exists: true,
      deactivated: false,
      currentAddress: address,
    }
  | AddressChanged({address}) => {...state, currentAddress: address}
  | CustomerDeactivated => {...state, deactivated: true}
  }

let decide = (state, command) =>
  switch command {
  | ChangeAddress({customerId, address}) =>
    if !state.exists {
      Error(CustomerNotFound)
    } else if state.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if address == state.currentAddress {
      Ok([]) // idempotent — address unchanged
    } else {
      Ok([AddressChanged({customerId, address})])
    }
  }
