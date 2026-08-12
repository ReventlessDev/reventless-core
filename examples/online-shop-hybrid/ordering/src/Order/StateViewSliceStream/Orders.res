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
      deliveryWindow: option<Reventless.DateRange.t>,
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
  // The order's owner. A shopper reading this view sees only the rows whose
  // `customerId` matches their own identity; a caller in an elevated group sees
  // every row. Enforced in the resolver, not by the client asking nicely.
  @owner customerId: string,
  productIds: array<string>,
  @status status: status,
  shippingMethod: shippingMethod,
  // Producer timestamps taken from the event envelope's `meta.time` — no need to
  // carry the time in the event payload. The `DateTime` marker surfaces
  // `format: "date-time"` on the state's JSON Schema, which the AutoUI date
  // views (Calendar/Timeline) key off. `shippedAt` is "" until the order ships.
  placedAt: @s.matches(Reventless.DateTime.string) string,
  shippedAt: @s.matches(Reventless.DateTime.string) string,
  // The requested delivery slot, carried straight from `OrderPlaced`. A declared
  // span — two ISO instants as one value — so a scheduler mode lays a bar out
  // from it directly, with `customerId` beside it as the row's resource ref,
  // instead of guessing the pair from field names. `None` until (and unless) an
  // order requests one.
  deliveryWindow: option<Reventless.DateRange.t>,
}
