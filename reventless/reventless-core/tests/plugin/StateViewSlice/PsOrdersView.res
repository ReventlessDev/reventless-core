// Test fixture spec for Phase 2 pluginStructure validation.
// OrdersView SVS: consumes order events (all with payloads for extractVariantNames).

@@reventless.spec("Orders")

@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string})

@schema
type state = {orderId: string}

let project = event =>
  switch event {
  | OrderPlaced({orderId}) => [Set(orderId, {orderId: orderId})]
  | OrderShipped({orderId}) => [Update(orderId, s => s)]
  | OrderCancelled({orderId}) => [Update(orderId, s => s)]
  }
