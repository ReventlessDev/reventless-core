// ProductDemand aggregate specification.
// Records per-product order demand, driven by Ordering's OrdersExtensionPoint.

@@reventless.spec

// Not a UI/API command — driven only by Ordering's OrdersExtensionPoint.
// @noApi removes it from the GraphQL/MCP/AutoUI surface, so the cross-plugin
// `orderId` is never rendered as a picker and needs no @ref.
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
