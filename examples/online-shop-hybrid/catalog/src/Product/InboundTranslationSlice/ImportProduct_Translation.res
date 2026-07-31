@@reventless.translation

// The feed already speaks in minor units, so the translation is a *parse* of its
// currency code rather than an arithmetic conversion: `Money.make` takes the two
// facts the supplier sent and nothing is scaled.
//
// This used to read `Int.toFloat(input.unitPrice) /. 100.0` and reject anything
// that was not USD — two halves of one mistake. The divide-by-100 was a minor
// unit hardcoded for the currencies that happen to have two, and the USD-only
// check was there because the domain had nowhere to put a currency once it had
// arrived. With `Money.t` the supplier's own currency survives the boundary, so
// a JPY feed — which has no decimals at all — needs no special case and gets none.
let translate = (input: externalInput) =>
  switch Reventless.Currency.fromString(input.currency) {
  | Error(why) => Error(why)
  | Ok(currency) =>
    if input.unitPrice <= 0 {
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
          price: Reventless.Money.make(~amount=Int.toFloat(input.unitPrice), ~currency),
          // Supplier feed carries no image — the optional imageUrl is simply absent.
          categoryId: input.category,
        }),
      )])
    }
  }
