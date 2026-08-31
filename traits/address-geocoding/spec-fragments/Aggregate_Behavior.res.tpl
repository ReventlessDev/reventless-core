// Scaffold: the behavior half of the graft. Paste into `Aggregate/{{Entity}}_Behavior.res`.

// --- state fields ------------------------------------------------------------
// Two fields, because there are three states and one `option` holds two: never
// asked, a point found, and a {{subject}} tried and found wanting (resolved-from,
// no point). Invariant every arm preserves: `locationResolvedFrom` is `None` or
// equal to `{{subject}}`.
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

// --- decide arms -------------------------------------------------------------
  | (Active(s), Update{{Subject}}({ {{subject}} })) if {{subject}} == s.{{subject}} => Ok([])
  | (Active(_), Update{{Subject}}({ {{subject}} })) => Ok([{{Subject}}Updated({ {{subject}}: {{subject}} })])

  // Idempotent only when *both* halves match — same {{subject}}, new point is a
  // correction, not a retry.
  | (Active(s), Set{{Subject}}Location({ {{subject}}, location}))
    if {{subject}} == s.{{subject}} && s.location == Some(location) => Ok([])
  | (Active(_), Set{{Subject}}Location({ {{subject}}, location})) =>
    Ok([{{Subject}}Located({ {{subject}}, location})])

  // Stale: a report on a {{subject}} this entity has since moved off.
  | (Active(s), SetLocation({resolvedFrom})) if resolvedFrom != s.{{subject}} => Ok([])
  // Redelivery: the slice re-publishes every heartbeat until its TODO clears.
  | (Active(s), SetLocation({location, resolvedFrom}))
    if s.location == Some(location) && s.locationResolvedFrom == Some(resolvedFrom) => Ok([])
  | (Active(_), SetLocation({location, resolvedFrom})) =>
    Ok([LocationSet({location, resolvedFrom})])

  // Same two guards for the verdict.
  | (Active(s), Mark{{Subject}}Unresolvable({ {{subject}} })) if {{subject}} != s.{{subject}} => Ok([])
  | (Active(s), Mark{{Subject}}Unresolvable({ {{subject}} }))
    if s.locationResolvedFrom == Some({{subject}}) => Ok([])
  | (Active(_), Mark{{Subject}}Unresolvable({ {{subject}}, reason})) =>
    Ok([{{Subject}}Unresolvable({ {{subject}}, reason})])

  // A retired entity has no location work owing — swallow, never error.
  | (Retired(_), SetLocation(_)) => Ok([])
  | (Retired(_), Mark{{Subject}}Unresolvable(_)) => Ok([])
