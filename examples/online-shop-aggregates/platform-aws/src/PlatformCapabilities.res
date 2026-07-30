// AUTO-GENERATED — do not edit. Run `pnpm run generate:platform` to update.
//
// The platform's capability list, unioned from the committed
// `capabilities.json` manifests of the plugins deploy-manifest.yaml names.
// Each entry keeps its declaring fields as provenance, so when a capability
// disappears from this list, the diff says which field's change removed it.

let capabilities: array<ReventlessInfra.Platform.capability> = [
  // catalog: Product.imageUrl @storageRef("productImages")
  // catalog: Products.imageUrl @storageRef("productImages")
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]
