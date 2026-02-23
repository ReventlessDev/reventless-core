// Product aggregate specification.
// A product listing with name, description, and price.

module Id = ReventlessSpec.Id.String

let name = "Product"

@schema
type command =
  | AddProduct({productId: string, name: string, description: string, price: float})
  | UpdateProductName({productId: string, name: string})
  | UpdateProductDescription({productId: string, description: string})
  | UpdateProductPrice({productId: string, price: float})

@schema
type event =
  | ProductAdded({productId: string, name: string, description: string, price: float})
  | ProductNameUpdated({productId: string, name: string})
  | ProductDescriptionUpdated({productId: string, description: string})
  | ProductPriceUpdated({productId: string, price: float})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound
