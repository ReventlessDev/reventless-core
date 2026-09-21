// AvailableProducts StateViewSliceStream.
// Projects synced catalog product events into a queryable "available products" read model.
// Hidden from AutoUI: the user-facing product list lives in the Catalog plugin;
// this denormalised mirror exists purely as an Ordering-side lookup target.

@@reventless.spec

// Rows are keyed by this identity.
module Key = CatalogSpec.ProductId
@@reventless.visibility(Internal)

@schema
type consumedEvent =
  | CatalogProductSynced({
      productId: CatalogSpec.ProductId.t,
      name: string,
      price: Reventless.Money.t,
    })
  | CatalogProductPriceChanged({productId: CatalogSpec.ProductId.t, price: Reventless.Money.t})
  | CatalogProductWithdrawn({productId: CatalogSpec.ProductId.t})
  | CatalogProductRelisted({
      productId: CatalogSpec.ProductId.t,
      name: string,
      price: Reventless.Money.t,
    })

@schema
type state = {productId: CatalogSpec.ProductId.t, name: string, price: Reventless.Money.t}
