// ProductDemand aggregate specification.
// Records per-product order demand, driven by Ordering's OrdersExtensionPoint.

open Reventless
module Id = Id.String

let name = "ProductDemand"

@schema
type command =
  | RecordDemand({productId: string, orderId: string})
  | RevokeDemand({productId: string, orderId: string})

@schema
type event =
  | ProductDemandRecorded({productId: string, orderId: string})
  | ProductDemandRevoked({productId: string, orderId: string})

@schema
type error = unit
