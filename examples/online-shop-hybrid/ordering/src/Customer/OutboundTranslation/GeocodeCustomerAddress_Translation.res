@@reventless.translation

// Keyed by entity *and* address: keying by entity alone would make a later
// address change look like work already done. `~sourceId` is the entity id,
// which an aggregate's event payload does not repeat.
let collect = (event, ~sourceId) =>
  switch event {
  | Registered({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  | AddressUpdated({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  }

// Asking the geocoder and reading its answer are the trait's — including the
// confidence rule, and the rule that an outage is not a verdict. The two
// commands the answer is reported through are this host's.
module Geocode = TraitAddressGeocoding.AddressGeocoding_Translate

let translate = async (_id, item, ~capabilities: Reventless.Capabilities.t) =>
  (
    await Geocode.translate(
      ~text=item.address,
      ~capabilities,
      ~located=(~point, ~resolvedFrom) => SetLocation({location: point, resolvedFrom}),
      // A verdict for a human, not a coordinate.
      ~unresolvable=(~subject, ~reason) =>
        MarkAddressUnresolvable({address: subject, reason}),
    )
  )->Result.map(command => Some((item.customerId, command)))

// The budget is spent and the geocoder never answered. Recording the verdict
// beats leaving the TODO pending forever — and it is why the capability must be
// declared, since an unprovisioned geocoder reaches here every time.
let onExhausted = (_id, item: outboundItem, ~lastError) =>
  Some((
    item.customerId,
    MarkAddressUnresolvable({
      address: item.address,
      reason: Geocode.exhaustedReason(lastError),
    }),
  ))
