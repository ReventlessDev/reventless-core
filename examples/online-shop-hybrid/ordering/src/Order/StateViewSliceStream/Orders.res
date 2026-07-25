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
  // Producer timestamps taken from the event envelope's `meta.time` — no need to
  // carry the time in the event payload. The `DateTime` marker surfaces
  // `format: "date-time"` on the state's JSON Schema, which the AutoUI date
  // views (Calendar/Timeline) key off. `shippedAt` is "" until the order ships.
  placedAt: @s.matches(Reventless.DateTime.string) string,
  shippedAt: @s.matches(Reventless.DateTime.string) string,
}
