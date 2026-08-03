// GeocodeCustomerAddress OutboundTranslationSlice.
//
// A human enters an address and nothing else. This slice turns that address into
// a point by asking Amazon Location, and reports the outcome back to the Customer
// aggregate — `SetLocation` when it is sure, `MarkAddressUnresolvable` when it is
// not. Neither command is callable from the API; see `Customer.res`.
//
// This is the *unattended* path. A client that can geocode for itself would send
// the point with the command and never reach here — `collect` is where that
// future arm goes, and it is the only place this slice would need to change.

@@reventless.spec

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

// Retries here are for a geocoder that is *down*, not for one that has answered.
// An address the service has no match for is resolved by publishing
// `MarkAddressUnresolvable`, not by trying again three times.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("Customer")

// The Customer aggregate, by its Spec.name — the capability that made this slice
// possible at all. Before it, an outbound slice could only read its plugin's DCB
// event log, and a customer's lifecycle is an aggregate.
let sourceNames = ["Customer"]

// Drawn as an external box outside the Ordering plugin in the Event Graph.
let externalSystem = Some("AwsLocation")
