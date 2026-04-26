// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement.
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced

@schema
type command =
  | PlaceOrder({
      orderId: string,
      customerId: string,
      productIds: array<string>,
    })

@schema
type error = OrderAlreadyPlaced

@schema
type event =
  | OrderPlaced({
      @partitionTag orderId: string,
      customerId: string,
      productIds: array<string>,
    })
