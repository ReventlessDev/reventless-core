// Products read model specification.
// Query-side state for product listings.

@@reventless.spec

module Id = CatalogSpec.ProductId

@schema
type state = {
  name: string,
  description: string,
  price: float,
  @storageRef("productImages") imageUrl: string,
}
