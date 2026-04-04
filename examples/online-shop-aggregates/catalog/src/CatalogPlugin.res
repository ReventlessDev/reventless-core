// Catalog plugin — platform-agnostic composition root.
// Wires the Product and Category aggregates and their read models,
// the ProductsExtensionPoint (outbound), and the OrdersExtension (inbound).

open Reventless.Projection

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    ReventlessInfra.NoEventMappings.Make(Product),
  )

  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  @reventless.projections
  module ProductProjections: Mappings with module Target := ProductsReadModel = {
    let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
  }

  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductProjections)

  @reventless.projections
  module CategoryProjections: Mappings with module Target := CategoriesReadModel = {
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryProjections)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemandBehavior,
    ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  @reventless.projections
  module DemandProjections: Mappings with module Target := ProductDemandReadModel = {
    let mappings: array<module(Mapping)> = [
      module(ProductDemandProjections.ProductMapping),
      module(ProductDemandProjections.ProductDemandMapping),
    ]
  }

  module ProductDemandReadModelMaker = Platform.ReadModel.Make(
    ProductDemandReadModel,
    DemandProjections,
  )

  // Build the Products extension point component
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    ProductsExtensionPoint.ProductMapping,
    {let moduleUrl: string = %raw(`import.meta.url`)},
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrdersExtension.DemandMapping,
  )

  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~aggregates=[
        module(ProductAggregate),
        module(CategoryAggregate),
        module(ProductDemandAggregate),
      ],
      ~readModels=[
        module(ProductReadModel),
        module(CategoryReadModel),
        module(ProductDemandReadModelMaker),
      ],
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~tasks=[module(ImportProductsTask)],
    )
}
