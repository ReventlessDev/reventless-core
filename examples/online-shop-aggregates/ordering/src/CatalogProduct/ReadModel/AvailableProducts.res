// AvailableProducts read model specification.
// Answers "which products can I order?" directly from the Ordering plugin —
// a denormalised mirror of Catalog.Products kept locally so Ordering doesn't
// need a cross-plugin call on every place-order request. Hidden from AutoUI
// because the user-facing product list lives in the Catalog plugin; this one
// exists purely as a lookup target.

@@reventless.spec
@@reventless.visibility(Internal)

@schema
type state = {name: string, price: float}

