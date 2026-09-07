// PlaceOrder StateChangeSlice.
// Rejects duplicate placement and validates that all referenced products are
// available (synced to the ordering event log, and not since withdrawn).

@@reventless.spec

// The full shelf lifecycle, not just its opening move. A slice that folded only
// `CatalogProductSynced` would decide on a set that never shrinks, and a product
// pulled from the catalog would stay orderable forever — the read side deletes
// the row while the write side keeps saying yes. Both the withdrawal and the way
// back are consumed, so availability follows the shelf in both directions.
//
// The price is read for the same reason the name is, and it is why pricing an
// order costs nothing here: Ordering already shadows what a placement needs to
// decide, so the total is computed from this fold rather than from a cross-plugin
// read or a read-model query issued out of a behaviour.
@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  // `name` is read as well as `productId`, so the order can record what the
  // product was called at the moment it was placed. The catalog publishes it on
  // both arms already; this slice simply stopped ignoring it.
  | CatalogProductSynced({productId: string, name: string, price: Reventless.Money.t})
  | CatalogProductPriceChanged({productId: string, price: Reventless.Money.t})
  | CatalogProductWithdrawn({productId: string})
  | CatalogProductRelisted({productId: string, name: string, price: Reventless.Money.t})
  // The picture the shelf currently shows, folded for the same reason the name
  // is: so a placement can copy it onto the order rather than the order having
  // to ask the catalog later.
  | CatalogProductImageChanged({productId: string, productImage?: Reventless.UploadableImage.t})

// Declared in the order the UI should present them: the batched default first,
// then the expedited option, then in-store collection.
@schema
type shippingMethod =
  | Standard
  | Express
  | Pickup

// One thing ordered, and how many of it. A **named** record rather than an inline
// one: the ppx walks a record type declaration, which is what puts the `@ref` (and
// with it the DCB tag) on `productId` where an inline record would carry neither.
//
// The framework finds the marker at this depth — the reference walk names it
// `lineItems[].productId`, and the tag walk gives it the key `productId`, which is
// the same tag the catalog's own events write.
@schema
type lineItem = {
  @ref("AvailableProducts") productId: string,
  quantity: int,
}

@schema
type command =
  PlaceOrder({
    @partitionTag orderId: string,
    // customerId is payload, not a query key — @noDcbTag stops it auto-tagging.
    // It is also the order's owner: the resolver overwrites this with the
    // authenticated caller's id before the command is published, so what a
    // client sends here is ignored rather than trusted. An operator placing an
    // order on someone's behalf is exempt and keeps the value they sent.
    @noDcbTag @owner customerId: string,
    lineItems: array<lineItem>,
    shippingMethod: shippingMethod,
    // A requested delivery slot, chosen at checkout. An optional field — a
    // Pickup order (or a caller that names no preference) simply omits it, and
    // an order placed before this field existed carries no key, so adding it
    // costs the log nothing (the additive path in the plan's adoption table).
    // One `DateRange.t`, not a guessed `start*`/`end*` name pair.
    deliveryWindow?: Reventless.DateRange.t,
  })

@schema
type error =
  | OrderAlreadyPlaced
  | ProductsNotAvailable({missing: array<string>})
  // An order for nothing is the one validation a shopper could trip before line
  // items existed: an empty product list placed an order and produced no lines.
  | OrderIsEmpty
  | InvalidQuantity({productId: string, quantity: int})
  // Refused rather than silently summed. `Money.add` returns a `result` for
  // exactly this case, and unwrapping it here would invent a total in whichever
  // currency happened to come first. Naming the codes says which shelf entries
  // disagree, the way `ProductsNotAvailable` names the products.
  | MixedCurrencies({currencies: array<string>})

// One priced line of a placed order, frozen at placement.
//
// **The price is the one the decision model held.** A later
// `CatalogProductPriceChanged` does not rewrite a placed order, which is why the
// total belongs on the event rather than in the projection.
@schema
type orderLine = {
  productId: string,
  name: string,
  quantity: int,
  unitPrice: Reventless.Money.t,
  lineTotal: Reventless.Money.t,
}

@schema
type event =
  OrderPlaced({
    @partitionTag orderId: string,
    customerId: string,
    // Redundant against `lines`, and deliberately so. The extension point
    // decomposes this into one published `ItemOrdered` per product and
    // `CancelOrder` folds it, so both keep working untouched — and the public
    // contract in `ordering-spec` does not move, which is what lets the shop
    // show quantities without redeploying Catalog in lockstep.
    productIds: array<string>,
    lines: array<orderLine>,
    total: Reventless.Money.t,
    shippingMethod: shippingMethod,
    deliveryWindow?: Reventless.DateRange.t,
    // What the first product was called when this order was placed.
    //
    // **Captured, not looked up.** An order is a record of what somebody bought,
    // and the catalog goes on changing afterwards — a rename, a withdrawal, a
    // reshoot. Reading the name live would rewrite history every time the shop
    // tidied its shelves, and would leave an order for a withdrawn product with
    // nothing to show at all.
    //
    // Optional because every order placed before this field existed carries no
    // key, which is what makes adding it cost the log nothing. A reader treats
    // absent as "not recorded" rather than as a name.
    firstProductName?: string,
    // The picture as it was when the order was placed, frozen for the reason the
    // name is. A reshoot, a withdrawal or a deletion afterwards leaves this
    // order showing what the shopper actually bought.
    @storageRef("Catalog.productImages") firstProductImage?: Reventless.UploadableImage.t,
  })
