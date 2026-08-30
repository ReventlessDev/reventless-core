// RecordProductDemand StateChangeSlice.
// Records and revokes per-product order demand driven by Ordering's extension point events.
@@reventless.spec

@schema
type consumedEvent =
  | ProductDemandRecorded({orderId: string})
  | ProductDemandRevoked({orderId: string})

// @noApi keeps this event-driven command off the GraphQL/MCP/AutoUI surface.
@schema @noApi
type command =
  | RecordDemand({productId: string, orderId: string})
  | RevokeDemand({productId: string, orderId: string})

@schema
type error = unit // always succeeds — demand recording is idempotent

@schema
type event =
  | ProductDemandRecorded({
      @partitionTag productId: string,
      orderId: string,
    })
  | ProductDemandRevoked({
      @partitionTag productId: string,
      orderId: string,
    })
