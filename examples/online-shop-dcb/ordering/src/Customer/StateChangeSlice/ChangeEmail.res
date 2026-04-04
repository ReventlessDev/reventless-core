// ChangeEmail StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when email is unchanged.
@@reventless.spec
@@reventless.dcbTags

type state = {exists: bool, deactivated: bool, currentEmail: string}

let initialState = {exists: false, deactivated: false, currentEmail: ""}

@schema
type consumedEvent =
  | CustomerRegistered({email: string})
  | EmailChanged({email: string})
  | CustomerDeactivated

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered({email}) => {exists: true, deactivated: false, currentEmail: email}
  | EmailChanged({email}) => {...state, currentEmail: email}
  | CustomerDeactivated => {...state, deactivated: true}
  }

@schema
type command = ChangeEmail({customerId: string, email: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

@schema
type event = EmailChanged({customerId: string, email: string})

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
