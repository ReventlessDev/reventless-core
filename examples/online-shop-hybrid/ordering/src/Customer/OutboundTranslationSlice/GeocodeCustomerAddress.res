// Turns an address into a point and reports back to the Customer aggregate:
// `SetLocation` when sure, `MarkAddressUnresolvable` when not. Neither is callable
// from the API. The unattended path — a client that geocodes for itself never
// reaches here, and `collect` is where that arm would go.

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

// Retries are for a geocoder that is down, not one that has answered.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("Customer")

// The Customer aggregate by its Spec.name; an outbound slice could once only read
// its plugin's DCB event log.
let sourceNames = ["Customer"]

// Drawn as an external box outside the Ordering plugin in the Event Graph.
let externalSystem = Some("AwsLocation")
