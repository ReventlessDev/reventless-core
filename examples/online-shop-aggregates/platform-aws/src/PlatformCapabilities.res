// AUTO-GENERATED — do not edit. Run `pnpm run generate:platform` to update.
//
// The platform's capability list, unioned from the committed
// `capabilities.json` manifests of the plugins deploy-manifest.yaml names.
// Each entry keeps its declaring sites as provenance, so when a capability
// disappears from this list, the diff says which change removed it.

let capabilities: array<ReventlessInfra.Platform.capability> = [
  // catalog: Product.imageUrl → productImages
  // catalog: Products.imageUrl → productImages
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]
