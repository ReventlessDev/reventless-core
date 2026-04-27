// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemandBehavior,
    ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  // ReadModels
  @reventless.projections
  module CategoriesProjectionsWrapper: Mappings with module Target := CategoriesReadModel = {
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }
  module CategoriesReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoriesProjectionsWrapper)
  @reventless.projections
  module ProductDemandProjectionsWrapper: Mappings with module Target := ProductDemandReadModel = {
    let mappings: array<module(Mapping)> = [module(ProductDemandProjections.ProductMapping), module(ProductDemandProjections.ProductDemandMapping)]
  }
  module ProductDemandReadModel = Platform.ReadModel.Make(ProductDemandReadModel, ProductDemandProjectionsWrapper)
  @reventless.projections
  module ProductsProjectionsWrapper: Mappings with module Target := ProductsReadModel = {
    let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
  }
  module ProductsReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductsProjectionsWrapper)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoints
  module ProductsExtensionPoint = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtension = Platform.Extension.Make(OrdersExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
    ~readModels=[module(CategoriesReadModel), module(ProductDemandReadModel), module(ProductsReadModel)],
    ~extensions=[module(OrdersExtension)],
  )

  let make = (~uiBundleUrl=?) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPoint)],
      ~extensions=[module(OrdersExtension)],
      ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
      ~readModels=[module(CategoriesReadModel), module(ProductDemandReadModel), module(ProductsReadModel)],
      ~tasks=[module(ImportProductsTask)],
      ~pluginStructure=pluginStructure,
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Catalog",
          ~aggregates=[module(CategoryAggregate), module(ProductAggregate), module(ProductDemandAggregate)],
          ~readModels=[module(CategoriesReadModel), module(ProductDemandReadModel), module(ProductsReadModel)],
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
