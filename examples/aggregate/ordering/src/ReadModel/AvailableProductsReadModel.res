// AvailableProducts read model specification.
// Answers "which products can I order?" directly from the Ordering plugin.

open Reventless
module Id = Id.String

@schema
type state = {productId: string, name: string, price: float}

let name = "AvailableProducts"

open Reventless.ReadModel
let config = config()
let subIdConfig = None
