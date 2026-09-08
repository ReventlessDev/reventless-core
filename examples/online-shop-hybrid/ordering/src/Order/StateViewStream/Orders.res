// Orders StateViewSliceStream.
// Projects order events from the shared ordering event log into an Orders read model.

@@reventless.spec

// Catalog's store, named explicitly: the ppx would otherwise derive an
// *Ordering* store from the field name, and nothing writes to that one.
let catalogProductImage = Reventless.UploadableImage.forField(
  ~plugin="Catalog",
  ~store="productImages",
)

@schema
type shippingMethod =
  | Standard
  | Express
  | Pickup

// One priced line, carried straight from `OrderPlaced` — the name and prices the
// write side froze at placement, not the catalog's current ones.
@schema
type orderLine = {
  productId: string,
  name: string,
  quantity: int,
  unitPrice: Reventless.Money.t,
  lineTotal: Reventless.Money.t,
}

@schema
type consumedEvent =
  | OrderPlaced({
      orderId: string,
      customerId: string,
      productIds: array<string>,
      lines: array<orderLine>,
      total: Reventless.Money.t,
      shippingMethod: shippingMethod,
      deliveryWindow: option<Reventless.DateRange.t>,
      firstProductName: option<string>,
      firstProductImage: @s.matches(S.option(catalogProductImage))
      option<Reventless.UploadableImage.t>,
    })
  | OrderShipped({orderId: string})
  | OrderCancelled({orderId: string})
  // Folding the cancellation without the reopen would render the row `Cancelled`
  // for the rest of its life. `ReopenOrder` being internal-only does not make
  // the edge less real.
  | OrderReopened({orderId: string})

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

// An order list is operational — an `AutoShipOrder` flips a row while the
// shopper is looking at it — so the Live control is offered.
@live(true) @schema
type state = {
  orderId: string,
  // Reads are narrowed to the caller's own rows in the resolver; an elevated
  // caller sees every row.
  @owner customerId: string,
  // Correct on the event, noise in a grid — `lines` says the same with names.
  @hidden productIds: array<string>,
  // From the envelope's `meta.time`. `@displayName` because an order placed
  // through the UI has a uuid for an id and no name of its own; `@summary` puts
  // the field a row is named by in the set a list column may show.
  @displayName @summary placedAt: Reventless.DateTime.t,
  // Every state this order reached and when, appended by the projection
  // machinery. Retires the per-state timestamp fields: a cancellation and a
  // reopen are dated without a projection edge for each, and a state added later
  // needs no new field.
  trail: Reventless.Lifecycle.Trail.t<lifecycle>,
  lines: array<orderLine>,
  // What the order cost, as the write side computed it at placement.
  @summary total: Reventless.Money.t,
  // How many things this is, summed across the lines — which the number of lines
  // does not give.
  @summary itemCount: int,
  // No annotation: the field name is the declaration. `@summary` because a view
  // declaring any summary field shows only those, and where an order has got to
  // is what a shopper scanning the list is looking for.
  @summary lifecycle: lifecycle,
  shippingMethod: shippingMethod,
  // The requested slot as one declared span, so a scheduler lays a bar out from
  // it directly instead of guessing the pair from field names.
  deliveryWindow: option<Reventless.DateRange.t>,
  // Carried on the event rather than read from the catalog — see `PlaceOrder`.
  // Absent on orders placed before it was recorded.
  firstProductName: option<string>,
  // The picture the order recorded, resolved as this row's own. Schema written
  // out because the store is Catalog's — see `catalogProductImage` above.
  firstProductImage: @s.matches(S.option(catalogProductImage)) option<Reventless.UploadableImage.t>,
}
