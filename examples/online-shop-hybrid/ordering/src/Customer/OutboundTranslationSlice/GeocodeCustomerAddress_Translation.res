@@reventless.translation

// Keyed by customer *and* address: keying by customer alone would make a later
// address change look like work already done. `~sourceId` is the customer id,
// which an aggregate's event payload does not repeat.
let collect = (event, ~sourceId) =>
  switch event {
  | Registered({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  | AddressUpdated({address}) => [(`${sourceId}:${address}`, {customerId: sourceId, address})]
  }

// The geocoder arrives as a capability: this plugin depends on `reventless-spec`,
// not `reventless-aws`, so the deployment decides what answers.
let translate = async (_id, item, ~capabilities: Reventless.Capabilities.t) => {
  let customerId = item.customerId
  let answer = await capabilities.geocode(~text=item.address)
  switch answer {
  // Matched only to keep `why`; `ofSearch` refuses this case too and is the rule.
  | Error(Unavailable(why)) => Error(`geocoder unavailable: ${why}`)
  | _ =>
    switch Reventless.Geolocation.ofSearch(~requestedFor=item.address, answer) {
    | Some(Located({point})) =>
      Ok(Some((customerId, SetLocation({location: point, resolvedFrom: item.address}))))
    // A verdict for a human, not a coordinate.
    | Some(Unresolvable({reason})) =>
      Ok(Some((customerId, MarkAddressUnresolvable({address: item.address, reason}))))
    | Some(Pending(_)) => Error("unreachable: ofSearch never answers Pending")
    | None => Error("geocoder unavailable")
    }
  }
}

// The point of the whole slice: `Pending` means the geocoder has not answered
// *yet*, and once the retries are spent there is no yet. Leaving the row Pending
// would put the wait and the giving-up back into one state, which is the collapse
// `Geolocation` exists to undo — so the customer is told the address could not be
// resolved, by the same event a confident refusal produces.
let onExhausted = (_id, item: outboundItem, ~lastError) =>
  Some((
    item.customerId,
    MarkAddressUnresolvable({
      address: item.address,
      reason: switch lastError {
      | Some(why) => `the geocoder never answered after repeated attempts (${why})`
      | None => "the geocoder never answered after repeated attempts"
      },
    }),
  ))
