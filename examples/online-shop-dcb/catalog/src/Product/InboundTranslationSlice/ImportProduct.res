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
}

@schema
type command = AddProduct({
  productId: string,
  name: string,
  description: string,
  price: float,
})

let targetName = "AddProduct"

let translate = input =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else if input.unitPrice <= 0 {
    Error("Price must be positive")
  } else if input.sku === "" {
    Error("SKU is required")
  } else {
    Ok([(
      input.sku,
      AddProduct({
        productId: input.sku,
        name: input.title,
        description: input.desc,
        price: Int.toFloat(input.unitPrice) /. 100.0,
      }),
    )])
  }
