// AvailableProducts read model specification.
// Answers "which products can I order?" directly from the Ordering plugin.

open Reventless
module Id = Id.String

@schema
type state = {name: string, price: float}

let name = "AvailableProducts"
let moduleUrl: string = %raw(`import.meta.url`)

open Reventless.ReadModel
let config = config()
let subIdConfig = None
