// Projection for `SvsTestSlice`. Hand-written `open` (no `@@reventless.projection`
// PPX in reventless-aws): `open Reventless.Projection` brings the action
// constructors (`UpdateMultiState`, …) into scope; `open SvsTestSlice` brings the
// consumed-event/state types.
//
// Every event upserts the cart's line for one product via `UpdateMultiState`,
// keyed by `productId` (the sub-id). This is the multi-state path that silently
// no-oped in the deployed runtime before `subIdConfig` was threaded.

open Reventless.Projection
open SvsTestSlice

let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
  switch event {
  | ItemAddedToCart({cartId, productId, qty}) => [
      UpdateMultiState(
        cartId,
        states => {
          let others = states->Array.filter(s => s.productId != productId)
          others->Array.concat([
            {cartId, productId, qty, fulfilment: Shipped({carrier: "dhl"})},
          ])
        },
      ),
    ]
  }
