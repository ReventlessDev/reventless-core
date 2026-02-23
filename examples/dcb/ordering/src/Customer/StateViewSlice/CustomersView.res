// CustomersView StateViewSlice.
// Projects customer events from the shared ordering event log into a Customers read model.

open ReventlessSpec.Projection
open OrderingEventLog

let name = "CustomersView"

module DcbEventLogSpec = OrderingEventLog

@schema
type event = OrderingEventLog.event

@schema
type state = {customerId: string, email: string, address: string, deactivated: bool}

let project = (_, event) =>
  switch event {
  | CustomerRegistered({customerId, email, address}) => [
      Set(customerId, {customerId, email, address, deactivated: false}),
    ]
  | EmailUpdated({customerId, email}) => [Update(customerId, state => {...state, email})]
  | AddressUpdated({customerId, address}) => [Update(customerId, state => {...state, address})]
  | CustomerDeactivated({customerId}) => [
      Update(customerId, state => {...state, deactivated: true}),
    ]
  | _ => [] // Order events are not handled by this view
  }
