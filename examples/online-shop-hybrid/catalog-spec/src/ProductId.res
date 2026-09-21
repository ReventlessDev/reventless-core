// A product's id. Declared in the published contract because Ordering keys its own
// copy of the catalog by it, so both plugins share one type.
include Reventless.Id.Make({
  let key = "productId"
})
