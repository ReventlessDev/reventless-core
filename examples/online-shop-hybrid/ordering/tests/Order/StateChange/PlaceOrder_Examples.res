@@reventless.examples

open PlaceOrder
open Ordering_Examples

// The line eleven tests place: one Fathom Dock at its shelf price.
let dockLine: orderLine = {
  productId: p1,
  name: fathomDock,
  quantity: 1,
  unitPrice: dockPrice,
  lineTotal: dockPrice,
}
