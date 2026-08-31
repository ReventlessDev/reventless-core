// Fragment: the slice body. Paste as `OutboundTranslationSlice/{{Slice}}_Translation.res`.
// Asking the geocoder and reading its answer are `AddressGeocoding_Translate`; the
// keying and the two commands the answer is reported through are the host's.

@@reventless.translation

module Geocode = TraitAddressGeocoding.AddressGeocoding_Translate

// Keyed by entity *and* {{subject}}: keying by entity alone would make a later
// change look like work already done. `~sourceId` is the entity id, which an
// aggregate's event payload does not repeat.
let collect = (event, ~sourceId) =>
  switch event {
  | {{Created}}({ {{subject}} }) => [(`${sourceId}:${ {{subject}} }`, { {{entityId}}: sourceId, {{subject}} })]
  | {{Subject}}Updated({ {{subject}} }) => [(`${sourceId}:${ {{subject}} }`, { {{entityId}}: sourceId, {{subject}} })]
  }

let translate = async (_id, item, ~capabilities: Reventless.Capabilities.t) =>
  (
    await Geocode.translate(
      ~text=item.{{subject}},
      ~capabilities,
      ~located=(~point, ~resolvedFrom) => SetLocation({location: point, resolvedFrom}),
      ~unresolvable=(~subject, ~reason) => Mark{{Subject}}Unresolvable({ {{subject}}: subject, reason}),
    )
  )->Result.map(command => Some((item.{{entityId}}, command)))

let onExhausted = (_id, item: outboundItem, ~lastError) =>
  Some((
    item.{{entityId}},
    Mark{{Subject}}Unresolvable({
      {{subject}}: item.{{subject}},
      reason: Geocode.exhaustedReason(lastError),
    }),
  ))
