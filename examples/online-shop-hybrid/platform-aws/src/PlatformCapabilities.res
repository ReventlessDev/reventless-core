// AUTO-GENERATED — do not edit. Run `pnpm run generate:platform` to update.
//
// The platform's capability list, unioned from the committed
// `capabilities.json` manifests of the plugins deploy-manifest.yaml names.
// Each entry keeps its declaring fields as provenance, so when a capability
// disappears from this list, the diff says which field's change removed it.

let capabilities: array<ReventlessInfra.Platform.capability> = [
  // catalog: AddCategory.categoryImage → categoryImages
  // catalog: Categories.categoryImage → categoryImages
  // catalog: ChangeCategoryImage.categoryImage → categoryImages
  ObjectStore({plugin: "Catalog", store: "categoryImages"}),
  // catalog: AddProduct.productImage → productImages
  // catalog: ChangeProductImage.productImage → productImages
  // catalog: ImportProduct.productImage → productImages
  // catalog: Products.productImage → productImages
  ObjectStore({plugin: "Catalog", store: "productImages"}),
]
