// A charger's id: the partition its registration decides about, the key of its row.
include Reventless.Id.Make({
  let key = "chargerId"
})
