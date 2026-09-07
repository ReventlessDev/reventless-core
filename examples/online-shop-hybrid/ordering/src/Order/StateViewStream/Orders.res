// Orders StateViewSliceStream.
// Projects order events from the shared ordering event log into an Orders read model.

@@reventless.spec

// Catalog's store, named explicitly. The ppx would otherwise derive a store from
// the field's name and declare an *Ordering* store nothing writes to; saying
// whose it is states what is true — Ordering holds a reference to bytes it can
// read and cannot put there.
let catalogProductImage = Reventless.UploadableImage.forField(
  ~plugin="Catalog",
  ~store="productImages",
)

@schema
type shippingMethod =
  | Standard
  | Express
  | Pickup

// One priced line of a placed order, carried straight from `OrderPlaced`. The
// name and the prices are the ones the write side froze at placement — this view
// does not go and ask the catalog what anything is called or costs now.
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
  // Consumed for the same reason the write side consumes it: a view that folds
  // a cancellation and ignores the reopen renders the row `Cancelled` for the
  // rest of its life, and no amount of correct decision-making upstream shows
  // through. `ReopenOrder` being internal-only does not make the edge less real.
  | OrderReopened({orderId: string})

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

// An order list is operational, not investigative — an `AutoShipOrder` flips a
// row while the shopper is looking at it — so the Live control is offered.
@live(true) @schema
type state = {
  orderId: string,
  // The order's owner. A shopper reading this view sees only the rows whose
  // `customerId` matches their own identity; a caller in an elevated group sees
  // every row. Enforced in the resolver, not by the client asking nicely.
  @owner customerId: string,
  // Correct on the event — it is what the extension point decomposes — and noise
  // in a grid, where `lines` says the same thing with names and quantities.
  @hidden productIds: array<string>,
  // Producer timestamps taken from the event envelope's `meta.time` — no need to
  // carry the time in the event payload. The `DateTime` marker surfaces
  // `format: "date-time"` on the state's JSON Schema, which the AutoUI date
  // views (Calendar/Timeline) key off. `shippedAt` is "" until the order ships.
  // `@displayName` because an order has no name of its own and its id is a uuid
  // for anything placed through the UI. When it was placed is what a customer
  // recognises it by, so that is what every surface calls it — the tracker's
  // heading, a card, and any other view referring to this order.
  //
  // `@summary` for the same reason: the field a row is *named* by belongs in the
  // set a list column may show, and a view that declares any summary field shows
  // only those.
  @displayName @summary placedAt: @s.matches(Reventless.DateTime.string) string,
  shippedAt: @s.matches(Reventless.DateTime.string) string,
  lines: array<orderLine>,
  // What the order cost, as the write side computed it at placement. Summary
  // fields because they are the two numbers a list column can usefully show.
  @summary total: Reventless.Money.t,
  // How many things this is, summed across the lines — a shopper's own reading
  // of the size of an order, which the number of lines does not give.
  @summary itemCount: int,
  // No annotation: the field name is the declaration. `@lifecycle` exists for
  // records whose lifecycle field is honestly called something else.
  lifecycle: lifecycle,
  shippingMethod: shippingMethod,
  // The requested delivery slot, carried straight from `OrderPlaced`. A declared
  // span — two ISO instants as one value — so a scheduler mode lays a bar out
  // from it directly, with `customerId` beside it as the row's resource ref,
  // instead of guessing the pair from field names. `None` until (and unless) an
  // order requests one.
  deliveryWindow: option<Reventless.DateRange.t>,
  // What the first product was called when the order was placed, carried on the
  // event rather than read from the catalog — see `PlaceOrder`. Absent on orders
  // placed before it was recorded, which is why it stays optional here too.
  firstProductName: option<string>,
  // The picture the order recorded, and the field the shell resolves as this
  // row's own — which is what puts it on a card without a renderer asking the
  // catalog for anything.
  //
  // The schema is written out rather than left to the ppx because the store is
  // **Catalog's**: the ppx derives a store from the field name, which would
  // declare an Ordering store nothing writes to. Naming the owning plugin says
  // what is true — Ordering holds a reference to bytes it can read and cannot
  // put there.
  firstProductImage: @s.matches(S.option(catalogProductImage)) option<Reventless.UploadableImage.t>,
}
