// Tells a charger the power it was limited to, through the devices capability:
// the domain names the kind and the instance, the platform carries it.
@@reventless.spec

@schema
type consumedEvent = PowerLimited({chargerId: string, powerKw: float})

@schema
type outboundItem = {chargerId: string, powerKw: float}

@schema
type inboundCommand = unit

let maxRetries = 3
let targetName = None
let sourceNames: array<string> = []
let externalSystem = Some("Chargers")
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
let traits: array<Reventless.Trait.t> = []
