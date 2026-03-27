# Flatten DcbSpec into Plugin.make Parameters

**Status**: Done
**Date**: 2026-03-27

## Goal

Remove the vestigial `Plugin.DcbSpec` module type and pass DCB slice arrays directly as labeled arguments on `Plugin.T.make`, matching how `~aggregates` and `~readModels` are already passed.

## Background

`DcbSpec` originally existed to carry `type event` with a `with type dcbEvent = event` constraint binding all slices to a shared event union. Since the decoupling commit (`2a40e8dd`), that constraint is gone — `DcbSpec` is now just a bag of 5 arrays with no type-level role. Flattening it simplifies the API and removes an unnecessary indirection.

## Changes

### 1. Update `Plugin.res` (reventless-infra)

- [x] Remove `module type DcbSpec`
- [x] Replace `~dcbSpec: module(DcbSpec)=?` on `Plugin.T.make` with 5 optional labeled args:
  ```rescript
  ~stateChangeSlices: array<module(StateChangeSlice.T)>=?,
  ~stateViewSlices: array<module(StateViewSlice.T)>=?,
  ~automationSlices: array<module(AutomationSlice.T)>=?,
  ~outboundTranslationSlices: array<module(OutboundTranslationSlice.T)>=?,
  ~inboundTranslationSlices: array<module(InboundTranslationSlice.T)>=?,
  ```

### 2. Update `Plugin_Builder.res` (reventless-core)

- [x] Change `construct` to accept the 5 optional arrays instead of `~dcbSpec: option<module(Plugin.DcbSpec)>`
- [x] Derive the "has DCB" flag from whether any slice array is non-empty (replaces the `switch dcbSpec` pattern)

### 3. Update `Dcb_Builder.res` (reventless-core)

- [x] Change `construct` signature: replace `~dcbSpec: option<module(Plugin.DcbSpec)>` with the 5 arrays directly
- [x] Remove `switch dcbSpec { | Some(module(DcbSpec)) => ... | None => emptyResult }` — use the arrays directly
- [x] Return `emptyResult` when all arrays are empty

### 4. Update Platform implementations

- [x] `reventless-aws/src/Platform.res` — update `Plugin.make` call forwarding
- [x] `reventless-in-memory/src/Platform.res` — update `Plugin.make` call forwarding

### 5. Update all plugin call sites

- [x] `examples/online-shop-dcb/catalog/src/Plugin/CatalogPlugin.res` — remove `module DcbSpec`, pass arrays directly
- [x] `examples/online-shop-dcb/ordering/src/Plugin/OrderingPlugin.res` — same
- [x] `examples/online-shop-hybrid/catalog/src/...` — same (if it uses DcbSpec)
- [x] `examples/online-shop-hybrid/ordering/src/...` — same
- [x] Any other plugin files referencing `DcbSpec`

### 6. Update documentation

- [x] `docs/guides/dcb-plugin-usage.md` — update DcbSpec section, usage examples, and architecture description
- [x] `docs/guides/platform-and-plugin-guide.md` — update if it references DcbSpec

### 7. Build and test

- [x] `npm run build` from root — zero warnings
- [x] `npm test` — all tests pass
- [x] Verify example E2E tests: `examples/online-shop-dcb/catalog/tests/`, `examples/online-shop-dcb/ordering/tests/`

## Example: Before → After

**Before** (CatalogPlugin.res):
```rescript
module DcbSpec = {
  let stateChangeSlices = [module(AddProductSlice), ...]
  let stateViewSlices = [module(ProductsViewSlice), ...]
  let automationSlices = []
  let outboundTranslationSlices = []
  let inboundTranslationSlices = []
}

let make = (~scheduler, ~api, ~apiRole) =>
  Platform.Plugin.make(
    ~name="Catalog",
    ~heartbeatInterval=60,
    ~scheduler,
    ~api, ~apiRole,
    ~dcbSpec=module(DcbSpec),
  )
```

**After**:
```rescript
let make = (~scheduler, ~api, ~apiRole) =>
  Platform.Plugin.make(
    ~name="Catalog",
    ~heartbeatInterval=60,
    ~scheduler,
    ~api, ~apiRole,
    ~stateChangeSlices=[module(AddProductSlice), ...],
    ~stateViewSlices=[module(ProductsViewSlice), ...],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
  )
```

Empty arrays can simply be omitted (all args are optional).
