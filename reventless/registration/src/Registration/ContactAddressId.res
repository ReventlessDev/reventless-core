// The address a registration claims, as the ledger knows it: the partition it
// decides about, and the tag that makes "this address is taken" one fact on every
// platform.
//
// Its value is a keyed fingerprint of the lower-cased address, never the address.
// A tag is an index key, and an index key cannot be encrypted or erased, so the
// address itself is carried beside it in a field of its own on the events that
// must reach the person. The key is the deployment's (`secrets.fingerprint`) and
// is never rotated: rotating it would orphan every registration recorded under
// the old one.
include Reventless.Id.Make({
  let key = "contactAddress"
})

/** What the fingerprint is taken under, so no other use of the deployment's key
    can produce the same value for an address. */
let purpose = "contactAddress"

/** The form every door takes the fingerprint of: an address differing only in
    case or surrounding spaces is the same registration. */
let normalize = (address: Reventless.Email.t): Reventless.Email.t =>
  address->Reventless.Email.toString->String.trim->String.toLowerCase->Reventless.Email.unsafe

/** The ledger's id for an address. Refused, never degraded to the address, when
    the deployment holds no key. */
let fingerprint = (secrets: Reventless.Secrets.t, address: Reventless.Email.t): result<t, string> =>
  switch secrets.fingerprint(~purpose, address->normalize->Reventless.Email.toString) {
  | Ok(value) => Ok(makeFromString(value))
  | Error(Unavailable(why)) => Error(`cannot fingerprint the address: ${why}`)
  }
