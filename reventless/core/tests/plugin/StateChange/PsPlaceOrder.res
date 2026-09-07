// Test fixture spec for Phase 2 pluginStructure validation.
// PlaceOrder SCS: consumes CatalogProductSynced (with payload), produces OrderPlaced.
// orderId in the command gets auto-tagged by the @@reventless.spec PPX (Instance-level).

@@reventless.spec("PlaceOrder")

type state = bool
let initialState = false

@schema
type consumedEvent = CatalogProductSynced({productId: string})

let evolve = (_state, _event) => true

@schema
type command = PlaceOrder({orderId: string})

@schema
type error = AlreadyPlaced

@schema
type event = OrderPlaced({orderId: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])
