// CustomersView StateViewSlice.
// Projects customer events from the shared ordering event log into a Customers read model.

open Reventless.Projection
open OrderingEventLog

let name = "CustomersView"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type event = OrderingEventLog.event

@schema
type state = {customerId: string, email: string, address: string, deactivated: bool}

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
  | _ => [] // Order events are not handled by this view
  }
