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
  categoryId: string,
})

let targetName = "AddProduct"
// Foreign system this anti-corruption slice receives product data from — drawn as an
// external box outside the Catalog plugin in the Event Graph.
let externalSystem = Some("SupplierFeed")
