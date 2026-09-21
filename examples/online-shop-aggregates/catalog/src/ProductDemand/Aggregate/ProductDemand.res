// ProductDemand aggregate specification.
// Records per-product order demand, driven by Ordering's OrdersExtensionPoint.

@@reventless.spec

module Id = CatalogSpec.ProductId

// @noApi keeps this event-driven command off the GraphQL/MCP/AutoUI surface.
@schema @noApi
type command =
  | Record({orderId: string})
  | Revoke({orderId: string})

@schema
type event =
  | Recorded({orderId: string})
  | Revoked({orderId: string})

@schema
type error = unit
