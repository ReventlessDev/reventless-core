@@reventless.translation

let translate = (input: externalInput) =>
  if input.currency !== "USD" {
    Error("Unsupported currency: " ++ input.currency)
  } else if input.unitPrice <= 0 {
    Error("Price must be positive")
  } else if input.sku === "" {
    Error("SKU is required")
  } else if input.category === "" {
    Error("Category is required")
  } else {
    Ok([(
      input.sku,
      AddProduct({
        productId: input.sku,
        name: input.title,
        description: input.desc,
        price: Int.toFloat(input.unitPrice) /. 100.0,
        // Supplier feed carries no image — the optional imageUrl is simply absent.
        categoryId: input.category,
      }),
    )])
  }
