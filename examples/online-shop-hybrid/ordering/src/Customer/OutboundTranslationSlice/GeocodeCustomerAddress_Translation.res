@@reventless.translation

// Keyed by customer *and* address: keying by customer alone would make a later
// address change look like work already done. `~sourceId` is the customer id,
// which an aggregate's event payload does not repeat.
let collect = (event, ~sourceId) =>
  switch event {
  | Registered({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  | AddressUpdated({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  }

// Asking the geocoder and reading its answer are the trait's; the two commands
// the answer is reported through are this host's.
module Geocode = TraitAddressGeocoding.AddressGeocoding_Translate

let translate = async (_id, item, ~capabilities: Reventless.Capabilities.t) =>
  (
    await Geocode.translate(
      ~text=item.address,
      ~capabilities,
      ~located=(~point, ~resolvedFrom) => SetLocation({location: point, resolvedFrom}),
      // A verdict for a human, not a coordinate.
      ~unresolvable=(~subject, ~reason) => MarkAddressUnresolvable({address: subject, reason}),
    )
  )->Result.map(command => Some((item.customerId, command)))

let onExhausted = (_id, item: outboundItem, ~lastError) =>
  Some((
    item.customerId,
    MarkAddressUnresolvable({
      address: item.address,
      reason: Geocode.exhaustedReason(lastError),
    }),
  ))
