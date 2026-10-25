// The address a registration claims: the partition the registration ledger
// decides about, and the tag that makes "this address is taken" one fact on
// every platform. Its value is the address itself, lower-cased.
include Reventless.Id.Make({
  let key = "contactAddress"
})
