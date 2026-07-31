// ImportProduct InboundTranslationSlice.
// Receives external supplier JSON, validates and translates to an AddProduct command.

@@reventless.spec

// The supplier's own shape, kept exactly as it arrives: `unitPrice` is a whole
// number of minor units and `currency` is a free string, because that is what
// the feed sends. Translating it into the domain's `Money.t` is this slice's
// job — that is what an anti-corruption layer is for.
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
  price: Reventless.Money.t,
  // The supplier feed carries no image, so this field is simply absent on the
  // mapped command — Product.AddProduct now models the image as optional.
  @storageRef("productImages") imageUrl?: string,
  categoryId: string,
})

let targetName = "AddProduct"
// Foreign system this anti-corruption slice receives product data from — drawn as an
// external box outside the Catalog plugin in the Event Graph.
let externalSystem = Some("SupplierFeed")
