# Plan: Update online-shop-aggregates to New App Structure

## Context

The DCB and hybrid examples already use the new conventions. The aggregates example has two structural gaps that need closing.

## Gaps

### 1. ExtensionPoint mapping files — old style

Both ExtensionPoint mapping files in the aggregates example use the pre-PPX pattern:
- No `@@reventless.spec` (manually `open ReventlessInfra.ExtensionPointMapping`)
- Filename ends in `ExtensionPoint` instead of `ExtensionPointMapping`
- Mapping is wrapped in a sub-module (e.g., `module ProductMapping = {...}`) instead of being flat at file level

Files:
- `catalog/src/ExtensionPoint/ProductsExtensionPoint.res`
- `ordering/src/ExtensionPoint/OrdersExtensionPoint.res`

New pattern (from DCB/hybrid examples):
```rescript
// ProductsExtensionPointMapping.res
@@reventless.spec   // PPX auto-injects: open ReventlessInfra.ExtensionPointMapping

module ExtensionPoint = CatalogSpec.ProductsExtensionPoint

module Delegate = {
  let name = Product.name  // or aggregate name
  module Id = Product.Id
  @schema type event = Product.event
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.Added({name, price}) => [PublishEvent(id, ExtensionPoint.ProductBecameAvailable({...}))]
  | _ => []
  }
)
```

The plugin wiring changes from:
```rescript
Platform.ExtensionPoint.Make(ProductsExtensionPoint.ProductMapping, ...)
```
to:
```rescript
Platform.ExtensionPoint.Make(ProductsExtensionPointMapping, ...)
```

### 2. Plugin files — not in `Plugin/` subfolder

Current:
- `catalog/src/CatalogPlugin.res`
- `ordering/src/OrderingPlugin.res`

Should be:
- `catalog/src/Plugin/CatalogPlugin.res`
- `ordering/src/Plugin/OrderingPlugin.res`

## Steps

### Step 1 — Migrate catalog ExtensionPoint mapping
- [ ] Rename `catalog/src/ExtensionPoint/ProductsExtensionPoint.res` → `catalog/src/ExtensionPoint/ProductsExtensionPointMapping.res`
- [ ] Rewrite to flat style with `@@reventless.spec` (see pattern above)
- [ ] Update `catalog/src/CatalogPlugin.res` to reference `ProductsExtensionPointMapping` directly

### Step 2 — Migrate ordering ExtensionPoint mapping
- [ ] Rename `ordering/src/ExtensionPoint/OrdersExtensionPoint.res` → `ordering/src/ExtensionPoint/OrdersExtensionPointMapping.res`
- [ ] Rewrite to flat style with `@@reventless.spec`
- [ ] Update `ordering/src/OrderingPlugin.res` to reference `OrdersExtensionPointMapping` directly

### Step 3 — Move plugin files into `Plugin/` subfolder
- [ ] Move `catalog/src/CatalogPlugin.res` → `catalog/src/Plugin/CatalogPlugin.res`
- [ ] Move `ordering/src/OrderingPlugin.res` → `ordering/src/Plugin/OrderingPlugin.res`
- [ ] Update `rescript.json` sources in both packages if needed (verify auto-discovery covers `Plugin/`)

### Step 4 — Build and verify
- [ ] Run `npm run build` from monorepo root
- [ ] Check for zero warnings: `npm run build 2>&1 | grep -E "Warning|warning|error|Error"`
- [ ] Remove stale compiled output from old paths if needed (`rescript clean`)

## Notes

- Extension files (`*Extension.res`) do NOT use `@@reventless.spec` — this is intentional and consistent across all three examples
- `SideEffect/` folder in aggregates ordering is a valid aggregate pattern (SideEffect.T interface) — do not change
- `EventMappings/` folder is also a valid aggregate pattern — do not change
