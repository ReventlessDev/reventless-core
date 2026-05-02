// ProductDemand aggregate specification.
// Records per-product order demand, driven by Ordering's OrdersExtensionPoint.

@@reventless.spec

@schema
type command =
  | Record({orderId: string})
  | Revoke({orderId: string})

@schema
type event =
  | Recorded({orderId: string})
  | Revoked({orderId: string})

@schema
type error = unit
