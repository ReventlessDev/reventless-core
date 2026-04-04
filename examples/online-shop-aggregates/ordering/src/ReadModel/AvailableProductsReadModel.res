// AvailableProducts read model specification.
// Answers "which products can I order?" directly from the Ordering plugin.

@@reventless.spec

@schema
type state = {name: string, price: float}

open Reventless.ReadModel
let config = config()
let subIdConfig = None
