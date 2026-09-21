// Maps internal Order events to the OrdersExtensionPoint public API, one published
// event per product in a batch.
@@reventless.spec

module ExtensionPoint = OrderingSpec.Orders_ExtensionPoint
module Delegate = Order

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some(
  (_id, event, _meta, _queryEngine) =>
    switch event {
    // The published contract carries plain strings: a consumer outside this
    // plugin has no OrderId or CustomerId type to hold them in.
    | Order.Placed({customerId, productIds}) =>
      productIds->Array.map(productId => {
        let productId = productId->CatalogSpec.ProductId.toString
        PublishEvent(
          productId,
          OrderingSpec.Orders_ExtensionPoint.ItemOrdered({
            productId,
            orderId: _id,
            customerId: customerId->CustomerId.toString,
          }),
        )
      })
    | Order.Cancelled({productIds}) =>
      productIds->Array.map(productId => {
        let productId = productId->CatalogSpec.ProductId.toString
        PublishEvent(
          productId,
          OrderingSpec.Orders_ExtensionPoint.ItemOrderCancelled({
            productId,
            orderId: _id,
          }),
        )
      })
    | _ => []
    },
)
