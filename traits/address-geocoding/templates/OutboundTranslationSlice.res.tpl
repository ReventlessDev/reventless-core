// Scaffold: the slice spec. Paste as `OutboundTranslationSlice/{{Slice}}.res`.
// Turns a {{subject}} into a point and reports back to `{{Entity}}`: `SetLocation`
// when sure, `Mark{{Subject}}Unresolvable` when not. Neither is callable from the API.

@@reventless.spec

// Only the triggers. The pair-supplying event is deliberately absent: the slice
// stands down when a client geocoded for itself.
@schema
type consumedEvent =
  | {{Created}}({ {{subject}}: string})
  | {{Subject}}Updated({ {{subject}}: string})

@schema
type outboundItem = { {{entityId}}: string, {{subject}}: string}

@schema
type inboundCommand =
  | SetLocation({location: Reventless.GeoPoint.t, resolvedFrom: string})
  | Mark{{Subject}}Unresolvable({ {{subject}}: string, reason: string})

// Retries are for a geocoder that is down, not one that has answered.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("{{Entity}}")
let sourceNames = ["{{Entity}}"]
let externalSystem = Some("Geocoder")
