// Scaffold: the slice body. Paste as `OutboundTranslationSlice/{{Slice}}_Translation.res`.

@@reventless.translation

// Keyed by entity *and* {{subject}}: keying by entity alone would make a later
// change look like work already done. `~sourceId` is the entity id, which an
// aggregate's event payload does not repeat.
let collect = (event, ~sourceId) =>
  switch event {
  | {{Created}}({ {{subject}} }) => [(`${sourceId}:${ {{subject}} }`, { {{entityId}}: sourceId, {{subject}} })]
  | {{Subject}}Updated({ {{subject}} }) => [(`${sourceId}:${ {{subject}} }`, { {{entityId}}: sourceId, {{subject}} })]
  }

// The geocoder arrives as a capability; the deployment decides what answers.
let translate = async (_id, item, ~capabilities: Reventless.Capabilities.t) => {
  let answer = await capabilities.geocode(~text=item.{{subject}})
  switch answer {
  // Matched only to keep `why`; `ofSearch` refuses this case too and is the rule.
  | Error(Unavailable(why)) => Error(`geocoder unavailable: ${why}`)
  | _ =>
    switch Reventless.Geolocation.ofSearch(~requestedFor=item.{{subject}}, answer) {
    | Some(Located({point})) =>
      Ok(Some((item.{{entityId}}, SetLocation({location: point, resolvedFrom: item.{{subject}}}))))
    | Some(Unresolvable({reason})) =>
      Ok(Some((item.{{entityId}}, Mark{{Subject}}Unresolvable({ {{subject}}: item.{{subject}}, reason}))))
    | Some(Pending(_)) => Error("unreachable: ofSearch never answers Pending")
    | None => Error("geocoder unavailable")
    }
  }
}

// Once the retries are spent there is no "yet": the entity is told the {{subject}}
// could not be resolved, by the same event a confident refusal produces.
let onExhausted = (_id, item: outboundItem, ~lastError) =>
  Some((
    item.{{entityId}},
    Mark{{Subject}}Unresolvable({
      {{subject}}: item.{{subject}},
      reason: switch lastError {
      | Some(why) => `the geocoder never answered after repeated attempts (${why})`
      | None => "the geocoder never answered after repeated attempts"
      },
    }),
  ))
