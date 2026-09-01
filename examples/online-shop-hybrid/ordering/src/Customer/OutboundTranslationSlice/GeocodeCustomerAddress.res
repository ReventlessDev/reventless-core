// GeocodeCustomerAddress: turns the address into a point and reports back to Customer —
// `SetLocation` when sure, `MarkAddressUnresolvable` when not. Neither is
// callable from the API.
//
// Emitted by the address-geocoding trait. Everything below is this host's own
// vocabulary, so it is ordinary source from here on — edit it freely.

@@reventless.spec

// Only the triggers. The event that carries address and point together is
// deliberately absent: the slice stands down when a client geocoded for itself,
// and the conformance suite asserts that this set is no wider than `collect`.
@schema
type consumedEvent =
  | Registered({email: string, address: string})
  | AddressUpdated({address: string})

@schema
type outboundItem = {customerId: string, address: string}

@schema
type inboundCommand =
  | SetLocation({location: Reventless.GeoPoint.t, resolvedFrom: string})
  | MarkAddressUnresolvable({address: string, reason: string})

// Retries are for a geocoder that is down, not one that has answered.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("Customer")

// The Customer aggregate by its Spec.name; an outbound slice could once only
// read its plugin's DCB event log.
let sourceNames = ["Customer"]

// Drawn as an external box outside this plugin in the Event Graph.
let externalSystem = Some("AwsLocation")

// The trait says what it reaches for; this host only names it. Spelling the
// capability here instead would be the one part of the graft nothing checks —
// an unprovisioned geocoder answers `Unavailable`, the retries run out, and
// every address is recorded as permanently unresolvable with no error raised.
let capabilityNeeds = TraitAddressGeocoding.AddressGeocoding.capabilityNeeds
