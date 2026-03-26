// CustomersView StateViewSlice.
// Projects customer events from the shared ordering event log into a Customers read model.

open Reventless.Projection

let name = "CustomersView"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type state = {customerId: string, email: string, address: string, deactivated: bool}

@schema
type consumedEvent =
  | CustomerRegistered({customerId: string, email: string, address: string})
  | EmailChanged({customerId: string, email: string})
  | AddressChanged({customerId: string, address: string})
  | CustomerDeactivated({customerId: string})

let project = event =>
  switch event {
  | CustomerRegistered({customerId, email, address}) => [
      Set(customerId, {customerId, email, address, deactivated: false}),
    ]
  | EmailChanged({customerId, email}) => [Update(customerId, state => {...state, email})]
  | AddressChanged({customerId, address}) => [Update(customerId, state => {...state, address})]
  | CustomerDeactivated({customerId}) => [
      Update(customerId, state => {...state, deactivated: true}),
    ]
  }
