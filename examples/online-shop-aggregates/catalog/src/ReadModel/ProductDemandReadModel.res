// ProductDemand read model specification.
// Tracks per-product order demand counts, combining data from Product and ProductDemand aggregates.

open Reventless
module Id = Id.String

@schema
type state = {name: string, orderCount: int}

let name = "ProductDemand"
let moduleUrl: string = %raw(`import.meta.url`)

open Reventless.ReadModel
let config = config()
let subIdConfig = None
