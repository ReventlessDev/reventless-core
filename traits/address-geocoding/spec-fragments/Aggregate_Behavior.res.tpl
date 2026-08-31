// Fragment: the behavior half of the graft. Paste into `Aggregate/{{Entity}}_Behavior.res`.
// Staleness, redelivery and the client-supplied pair are `AddressGeocoding_Guards`;
// the state and the facts stay the host's.

module Guards = TraitAddressGeocoding.AddressGeocoding_Guards

// --- state fields ------------------------------------------------------------
// Two fields, because there are three states and one `option` holds two: never
// asked, a point found, and a {{subject}} tried and found wanting (resolved-from,
// no point). Host-owned, not the trait's record: an aggregate's state is
// snapshotted, so a trait release that reshaped it would be a migration.
// Invariant every arm preserves: `locationResolvedFrom` is `None` or equal to
// `{{subject}}`.
      location: option<Reventless.GeoPoint.t>,
      locationResolvedFrom: option<string>,

// --- evolve arms -------------------------------------------------------------
  // A new {{subject}} invalidates what was known; dropping both puts the row back
  // in front of the slice.
  | (Active(s), {{Subject}}Updated({ {{subject}} })) =>
    Active({...s, {{subject}}, location: None, locationResolvedFrom: None})
  | (Active(s), LocationSet({location, resolvedFrom})) =>
    Active({...s, location: Some(location), locationResolvedFrom: Some(resolvedFrom)})
  // The caller supplied the pair, so there is nothing left to resolve.
  | (Active(s), {{Subject}}Located({ {{subject}}, location})) =>
    Active({...s, {{subject}}, location: Some(location), locationResolvedFrom: Some({{subject}})})
  // Recording the {{subject}} keeps the slice from handing it back for another round.
  | (Active(s), {{Subject}}Unresolvable({ {{subject}} })) =>
    Active({...s, location: None, locationResolvedFrom: Some({{subject}})})

// --- the trait's view, and what it decides -----------------------------------
// Built per call from the fields above, because the inline record of `Active`
// cannot escape its constructor.
let resolution = ({{subject}}, location, locationResolvedFrom): Guards.resolution => {
  subject: {{subject}},
  location,
  resolvedFrom: locationResolvedFrom,
}

let appended = (verdict, event) =>
  switch verdict {
  | Guards.Append => Ok([event])
  | Guards.Ignore => Ok([])
  }

// --- decide arms -------------------------------------------------------------
  | (Active(s), Update{{Subject}}({ {{subject}} })) =>
    Guards.onSubjectUpdate(
      resolution(s.{{subject}}, s.location, s.locationResolvedFrom),
      ~subject={{subject}},
    )->appended({{Subject}}Updated({ {{subject}}: {{subject}} }))

  | (Active(s), Set{{Subject}}Location({ {{subject}}, location})) =>
    Guards.onSuppliedPair(
      resolution(s.{{subject}}, s.location, s.locationResolvedFrom),
      ~subject={{subject}},
      ~location,
    )->appended({{Subject}}Located({ {{subject}}, location}))

  | (Active(s), SetLocation({location, resolvedFrom})) =>
    Guards.onLocationReport(
      resolution(s.{{subject}}, s.location, s.locationResolvedFrom),
      ~location,
      ~resolvedFrom,
    )->appended(LocationSet({location, resolvedFrom}))

  | (Active(s), Mark{{Subject}}Unresolvable({ {{subject}}, reason})) =>
    Guards.onUnresolvableReport(
      resolution(s.{{subject}}, s.location, s.locationResolvedFrom),
      ~subject={{subject}},
    )->appended({{Subject}}Unresolvable({ {{subject}}, reason}))

  // A retired entity has no location work owing — swallow, never error.
  | (Retired(_), SetLocation(_)) => Ok([])
  | (Retired(_), Mark{{Subject}}Unresolvable(_)) => Ok([])
