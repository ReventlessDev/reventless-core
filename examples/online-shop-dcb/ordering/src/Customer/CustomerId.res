// A customer's id: the partition its slices decide about, and an order's buyer.
include Reventless.Id.Make({
  let key = "customerId"
})
