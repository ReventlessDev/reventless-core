@@reventless.translation

let translate = input =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else if input.unitPrice <= 0 {
    Error("Price must be positive")
  } else if input.sku === "" {
    Error("SKU is required")
  } else {
    Ok([
      (
        input.sku,
        AddProduct({
          // The external SKU becomes the catalog's product id here, at the edge.
          productId: CatalogSpec.ProductId.makeFromString(input.sku),
          name: input.title,
          description: input.desc,
          price: Int.toFloat(input.unitPrice) /. 100.0,
        }),
      ),
    ])
  }
