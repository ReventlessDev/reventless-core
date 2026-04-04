// ProductDemand read model specification.
// Tracks per-product order demand counts, combining data from Product and ProductDemand aggregates.

@@reventless.spec

@schema
type state = {name: string, orderCount: int}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
