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

  module ProductProjections: Mappings with module Target := ProductsReadModel = {
    module M = Mappings.Make(ProductsReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [module(ProductsProjections.ProductMapping)]
  }

  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductProjections)

  module CategoryProjections: Mappings with module Target := CategoriesReadModel = {
    module M = Mappings.Make(CategoriesReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryProjections)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemandBehavior,
    ReventlessInfra.NoEventMappings.Make(ProductDemand),
  )

  module DemandProjections: Mappings with module Target := ProductDemandReadModel = {
    module M = Mappings.Make(ProductDemandReadModel)
    module type Mapping = M.Mapping
    let mappings: array<module(Mapping)> = [
      module(ProductDemandProjections.ProductMapping),
      module(ProductDemandProjections.ProductDemandMapping),
    ]
  }

  module ProductDemandReadModelMaker = Platform.ReadModel.Make(
    ProductDemandReadModel,
    DemandProjections,
  )

  // Compile the Products extension point mappings, then build the EP component
  module ProductsEPProductMapping = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionPoint.ProductMapping,
  )
  module ProductsEPMappings = {
    module Spec = CatalogSpec.ProductsExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPProductMapping)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsEPMappings,
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtension.DemandMapping,
  )
  module OrdersExtensionMappings: ReventlessInfra.ExtensionMapping.Mappings
    with module Spec := OrderingSpec.OrdersExtensionPoint = {
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := OrderingSpec.OrdersExtensionPoint
    let name = "CatalogDemand"
    let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
  }
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionMappings,
  )

  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  let make = (~scheduler, ~api, ~apiRole) =>
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
      ~api,
      ~apiRole,
      ~scheduler,
    )
}
