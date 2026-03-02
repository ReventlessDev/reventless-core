// ProductDemand read model specification.
// Tracks per-product order demand counts, combining data from Product and ProductDemand aggregates.

open Reventless
module Id = Id.String

@schema
type state = {productId: string, name: string, orderCount: int}

let name = "ProductDemand"

open Reventless.ReadModel
let config = config()
let subIdConfig = None
