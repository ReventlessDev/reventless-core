// OrdersView StateViewSlice.
// Projects order events from the shared ordering event log into an Orders read model.
@@reventless.spec


open Reventless.Projection


@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  status: string, // "placed" | "shipped" | "cancelled"
}

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string, productIds: array<string>})
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string})

let project = event =>
  switch event {
  | OrderPlaced({orderId, customerId, productIds}) => [
      Set(orderId, {orderId, customerId, productIds, status: "placed"}),
    ]
  | OrderShipped({orderId}) => [Update(orderId, state => {...state, status: "shipped"})]
  | OrderCancelled({orderId}) => [Update(orderId, state => {...state, status: "cancelled"})]
  }
