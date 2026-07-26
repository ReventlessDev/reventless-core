// ImportProduct InboundTranslationSlice.
// Receives external supplier JSON, validates and translates to an AddProduct command.

@@reventless.spec

@schema
type externalInput = {
  sku: string,
  title: string,
  desc: string,
  unitPrice: int,
  currency: string,
  category: string,
}

@schema
type command = AddProduct({
  productId: string,
  name: string,
  description: string,
  price: float,
  // Product.AddProduct requires an imageUrl; the supplier feed carries no image,
  // so the translation supplies an empty string (no thumbnail) rather than
  // omitting the field, which would reject the mapped command downstream.
  imageUrl: string,
  categoryId: string,
})

let targetName = "AddProduct"
// Foreign system this anti-corruption slice receives product data from — drawn as an
// external box outside the Catalog plugin in the Event Graph.
let externalSystem = Some("SupplierFeed")
