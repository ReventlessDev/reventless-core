// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.CATALOG_UI_BUNDLE_URL"

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    Category_Behavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    Product_Behavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemand_Behavior,
    ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  // ReadModels
  module CategoriesReadModel = Platform.ReadModel.Make(Categories, Categories_Projections)
  module ProductDemandsReadModel = Platform.ReadModel.Make(ProductDemands, ProductDemands_Projections)
  module ProductsReadModel = Platform.ReadModel.Make(Products, Products_Projections)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoints
  module Products_ExtensionPoint = Platform.ExtensionPoint.Make(Products_ExtensionPointMapping)

  // Extensions
  module Orders_Extension = Platform.Extension.Make(Orders_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
    ~readModels=[module(CategoriesReadModel), module(ProductDemandsReadModel), module(ProductsReadModel)],
    ~extensions=[module(Orders_Extension)],
    ~extensionPoints=[module(Products_ExtensionPointMapping)],
    ~componentChapters=Dict.fromArray([("Categories", "Category"), ("Category", "Category"), ("Product", "Product"), ("ProductDemand", "ProductDemand"), ("ProductDemands", "ProductDemand"), ("Products", "Product")]),
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Products_ExtensionPoint)],
      ~extensions=[module(Orders_Extension)],
      ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
      ~readModels=[module(CategoriesReadModel), module(ProductDemandsReadModel), module(ProductsReadModel)],
      ~tasks=[module(ImportProductsTask)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Catalog",
          ~pluginStructure,
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
