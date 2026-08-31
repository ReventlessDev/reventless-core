// Scaffold: the aggregate half of the graft. Paste into `Aggregate/{{Entity}}.res`.
// `{{subject}}` is the address field (a `string` today); `{{Subject}}` its capitalised form.

// --- command arms ------------------------------------------------------------
// A human enters an address and nothing else. `{{Slice}}` — an
// OutboundTranslationSlice subscribed to this aggregate — turns it into a point and
// reports back through the two `@noApi` commands. Whoever supplies a point supplies
// the address it belongs to, so a caller never sends a bare coordinate: `SetLocation`
// is the slice's shape and stays internal; a client corrects a row through
// `Set{{Subject}}Location`, which is an assertion about the present and wins.
  // Change the {{subject}} and let the geocoder find the point.
  | Update{{Subject}}({ {{subject}}: string})
  // Change the {{subject}} *and* say where it is. Suppresses the geocoder for it.
  | Set{{Subject}}Location({ {{subject}}: string, location: Reventless.GeoPoint.t})
  // `resolvedFrom` is a staleness token: an answer for a {{subject}} that has since
  // changed is dropped rather than applied. Deliberately unguarded — legal in every
  // state, `Ok([])` on a retired entity, so an in-flight answer never parks a TODO.
  | @noApi SetLocation({location: Reventless.GeoPoint.t, resolvedFrom: string})
  | @noApi Mark{{Subject}}Unresolvable({ {{subject}}: string, reason: string})

// --- event arms --------------------------------------------------------------
  | {{Subject}}Updated({ {{subject}}: string})
  // `resolvedFrom` is provenance, not the {{subject}} of record; it is what makes
  // "is the pin still current?" decidable.
  | LocationSet({location: Reventless.GeoPoint.t, resolvedFrom: string})
  // Both halves from a client. Not `{{Subject}}Updated` + `LocationSet`: the slice
  // collects the former, and this event is not in its consumed set — the stand-down.
  | {{Subject}}Located({ {{subject}}: string, location: Reventless.GeoPoint.t})
  // A fact, not an absence: `location: None` already means "not looked up yet".
  | {{Subject}}Unresolvable({ {{subject}}: string, reason: string})
