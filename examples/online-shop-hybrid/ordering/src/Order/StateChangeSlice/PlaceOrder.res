// PlaceOrder StateChangeSlice.
// Rejects duplicate placement and validates that all referenced products are
// available (synced to the ordering event log, and not since withdrawn).

@@reventless.spec

// The full shelf lifecycle, not just its opening move. A slice that folded only
// `CatalogProductSynced` would decide on a set that never shrinks, and a product
// pulled from the catalog would stay orderable forever — the read side deletes
// the row while the write side keeps saying yes. Both the withdrawal and the way
// back are consumed, so availability follows the shelf in both directions.
@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | CatalogProductSynced({productId: string})
  | CatalogProductWithdrawn({productId: string})
  | CatalogProductRelisted({productId: string})

// Declared in the order the UI should present them: the batched default first,
// then the expedited option, then in-store collection.
@schema
type shippingMethod =
  | Standard
  | Express
  | Pickup

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
    @ref("AvailableProducts") productIds: array<string>,
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

@schema
type event =
  OrderPlaced({
    @partitionTag orderId: string,
    customerId: string,
    productIds: array<string>,
    shippingMethod: shippingMethod,
    deliveryWindow?: Reventless.DateRange.t,
  })
