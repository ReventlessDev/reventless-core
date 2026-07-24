// Orders StateViewSliceStream.
// Projects order events from the shared ordering event log into an Orders read model.

@@reventless.spec

@schema
type shippingMethod =
  | Standard
  | Express
  | Pickup

@schema
type consumedEvent =
  | OrderPlaced({
      orderId: string,
      customerId: string,
      productIds: array<string>,
      shippingMethod: shippingMethod,
    })
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string})

@schema
type status =
  | Placed
  | Shipped
  | Cancelled

@schema
type state = {
  orderId: string,
  customerId: string,
  productIds: array<string>,
  @status status: status,
  shippingMethod: shippingMethod,
}
