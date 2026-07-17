// Tiny StateViewSlice spec exercised by
// `StateViewSliceEntryPoint_IntegrationTest`. Standalone schema — does not
// depend on the example apps — so the fixture's shape can drift independently
// of any shipped slice.
//
// Hand-written explicit form rather than the `@@reventless.spec` PPX shorthand:
// the reventless-ppx is only wired into reventless-core's rescript.json, not
// reventless-aws's. So `consumedEventSchema`, `subIdConfig` etc. are declared
// directly.
//
// The slice models a per-cart, per-product line: primary id = `cartId`,
// sub-id = `productId`. Its projection uses `UpdateMultiState`, the action that
// hits the runtime's `subIdConfig` guard — the exact path the deployed entry
// point used to no-op by hardcoding `subIdConfig = undefined`.

@schema
type consumedEvent = ItemAddedToCart({cartId: string, productId: string, qty: int})

@schema
type state = {
  cartId: string,
  productId: string,
  qty: int,
}

// `Some({subIdField, getSubId})` — the compiled per-slice spec that a real
// `@subId productId` view slice carries. `subIdField` is the DynamoDB range-key
// attribute; `getSubId` extracts it from a projected state row.
let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = Some({
  subIdField: "productId",
  getSubId: state => state.productId,
})
