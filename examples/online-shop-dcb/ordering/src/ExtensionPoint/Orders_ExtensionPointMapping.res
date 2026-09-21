// Maps internal Ordering events to the Orders_ExtensionPoint public API, one
// published event per product in a batch.
@@reventless.spec

module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint

// DCB adapter carrying only the events this port maps.
module Delegate = {
  let name = "OrderingDcbEventLog"
  @schema
  type event =
    | OrderPlaced({
        orderId: OrderId.t,
        customerId: CustomerId.t,
        productIds: array<CatalogSpec.ProductId.t>,
      })
    | OrderCancelled({orderId: OrderId.t, productIds: array<CatalogSpec.ProductId.t>})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some(
  (_id, event, _meta, _queryEngine) =>
    // The published contract carries plain strings: a consumer outside this
    // plugin has no OrderId or CustomerId type to hold them in.
    switch event {
    | Delegate.OrderPlaced({orderId, customerId, productIds}) =>
      productIds->Array.map(productId => {
        let productId = productId->CatalogSpec.ProductId.toString
        PublishEvent(
          productId,
          OrderingSpec.Orders_ExtensionPoint.ItemOrdered({
            productId,
            orderId: orderId->OrderId.toString,
            customerId: customerId->CustomerId.toString,
          }),
        )
      })
    | Delegate.OrderCancelled({orderId, productIds}) =>
      productIds->Array.map(productId => {
        let productId = productId->CatalogSpec.ProductId.toString
        PublishEvent(
          productId,
          OrderingSpec.Orders_ExtensionPoint.ItemOrderCancelled({
            productId,
            orderId: orderId->OrderId.toString,
          }),
        )
      })
    },
)
