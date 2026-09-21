// An order's id: the Order stream and the Orders rows are keyed by it.
include Reventless.Id.Make({
  let key = "orderId"
})
