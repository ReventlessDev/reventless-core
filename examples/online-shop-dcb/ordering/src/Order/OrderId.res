// An order's id: the partition its slices decide about, and the key of its rows.
include Reventless.Id.Make({
  let key = "orderId"
})
