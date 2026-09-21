// ProductDemand read model specification.
// Tracks per-product order demand counts, combining data from Product and ProductDemand aggregates.

@@reventless.spec

module Id = CatalogSpec.ProductId

@schema
type state = {name: string, orderCount: int}
