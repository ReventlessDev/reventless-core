@@reventless.translation

// Keyed by customer *and* address. Keying by customer alone would make a later
// address change look like work already done (phase 1 skips an id it has seen),
// so the corrected address would never be geocoded.
//
// `~sourceId` is the customer id: an aggregate's event payload does not repeat
// the id that addressed it, so this is the only place it is available.
//
// When a client can geocode for itself, its arm goes here — an event arriving
// with a point already on it returns `[]` and this slice never spends a request
// on it. That is the whole forward-compatibility story, and it is one `switch`
// arm rather than a reshaping of the slice.
let collect = (event, ~sourceId) =>
  switch event {
  | Registered({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  | AddressUpdated({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  }

// The geocoder arrives as a capability rather than being reached for. This
// plugin cannot name Amazon Location — it depends on `reventless-spec`, not on
// `reventless-aws` — and under this shape it does not need to: the deployment
// decides what answers, and nothing below changes when that answer does.
let translate = async (_id, item, ~capabilities: Reventless.Capabilities.t) => {
  let customerId = item.customerId
  switch await capabilities.geocode(~text=item.address) {
  | Error(Unavailable(why)) =>
    // Retryable: the service could not answer. Do NOT report a verdict on the
    // address — one outage would otherwise mark every address in flight bad.
    Error(`geocoder unavailable: ${why}`)
  | Error(NoMatch) =>
    Ok(
      Some((
        customerId,
        MarkAddressUnresolvable({address: item.address, reason: "no match for this address"}),
      )),
    )
  | Ok(candidates) =>
    switch candidates->Reventless.Geocoding.confidentMatch {
    | Some(match) =>
      Ok(Some((customerId, SetLocation({location: match.point, resolvedFrom: item.address}))))
    | None =>
      // The service matched something, loosely or several things about equally
      // well. Storing the top hit here is how a confident pin lands in the wrong
      // region, so this is a verdict for a human, not a coordinate.
      Ok(
        Some((
          customerId,
          MarkAddressUnresolvable({
            address: item.address,
            reason: "no confident match — the address is ambiguous or too vague",
          }),
        )),
      )
    }
  }
}
