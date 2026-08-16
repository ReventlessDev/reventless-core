@@reventless.projection

let project = ({event}) =>
  switch event {
  | CatalogProductSynced({productId, name, price}) => [Set(productId, {productId, name, price})]
  | CatalogProductPriceChanged({productId, price}) =>
    [Update(productId, p => {...p, price})]
  // `Delete`, not a flag. This view answers "what can I order", so a withdrawn
  // product leaves it. Marking it instead — `@retired` on the shopper view —
  // would look tidy and be wrong twice over: a shopper is not elevated, so the
  // narrowing would hide it correctly, but an operator IS, and would find
  // discontinued stock in the shopper's catalog. It would also make Ordering
  // restate a lifecycle Catalog owns.
  | CatalogProductWithdrawn({productId}) => [Delete(productId)]
  // Set again, from the relist event's own payload — which the aggregate filled
  // from the shadow it kept through the withdrawal. Catalog is never asked to
  // re-send what Ordering already has.
  | CatalogProductRelisted({productId, name, price}) => [Set(productId, {productId, name, price})]
  }
