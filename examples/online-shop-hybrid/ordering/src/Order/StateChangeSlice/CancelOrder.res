// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

open Reventless

let name = "CancelOrder"
let moduleUrl: string = %raw(`import.meta.url`)

type state = {exists: bool, shipped: bool, cancelled: bool, productIds: array<string>}

let initialState = {exists: false, shipped: false, cancelled: false, productIds: []}

@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>})
  | OrderShipped
  | OrderCancelled

let evolve = (state, event) =>
  switch event {
  | OrderPlaced({productIds}) => {exists: true, shipped: false, cancelled: false, productIds}
  | OrderShipped => {...state, shipped: true}
  | OrderCancelled => {...state, cancelled: true}
  }

@schema
type command = CancelOrder({orderId: @s.matches(DcbTag.string) string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

@schema
type producedEvent =
  | OrderCancelled({
      orderId: @s.matches(DcbTag.string) string,
      productIds: array<string>,
    })

let decide = (state, command) =>
  switch command {
  | CancelOrder({orderId: theId}) =>
    if !state.exists {
      Error(OrderNotFound)
    } else if state.shipped {
      Error(OrderAlreadyShipped)
    } else if state.cancelled {
      Ok([]) // idempotent — already cancelled
    } else {
      Ok([OrderCancelled({orderId: theId, productIds: state.productIds})])
    }
  }
