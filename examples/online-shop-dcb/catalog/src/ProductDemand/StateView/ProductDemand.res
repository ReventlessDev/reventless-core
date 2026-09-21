// ProductDemand StateViewSlice.
// Projects catalog events into a per-product demand counter (order count).
@@reventless.spec

// Rows are keyed by this identity.
module Key = CatalogSpec.ProductId

@schema
type state = {productId: CatalogSpec.ProductId.t, name: string, orderCount: int}

@schema
type consumedEvent =
  | ProductAdded({productId: CatalogSpec.ProductId.t, name: string})
  | ProductDemandRecorded({productId: CatalogSpec.ProductId.t})
  | ProductDemandRevoked({productId: CatalogSpec.ProductId.t})
