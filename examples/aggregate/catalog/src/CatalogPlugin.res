// Catalog plugin — platform-agnostic composition root.
// Wires the Product and Category aggregates and their read models,
// the ProductsExtensionPoint (outbound), and the OrdersExtension (inbound).

open Reventless
open Reventless.Projection

module Make = (Platform: Platform.T) => {
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    NoEventMappings.Make(Product),
  )

  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    NoEventMappings.Make(Category),
  )

  module ProductMappings: Mappings with module Target := ProductsReadModel = {
    module ProductMappings = Mappings.Make(ProductsReadModel)
    module type Mapping = ProductMappings.Mapping
    let mappings = ProductsProjections.mappings
  }

  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductMappings)

  module CategoryMappings: Mappings with module Target := CategoriesReadModel = {
    module CategoryMappings = Mappings.Make(CategoriesReadModel)
    module type Mapping = CategoryMappings.Mapping
    let mappings = CategoriesProjections.mappings
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryMappings)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module ProductDemandAggregate = Platform.Aggregate.Make(
    ProductDemand,
    ProductDemandBehavior,
    NoEventMappings.Make(ProductDemand),
  )

  module ProductDemandMappings: Mappings with module Target := ProductDemandReadModel = {
    module ProductDemandMappings = Mappings.Make(ProductDemandReadModel)
    module type Mapping = ProductDemandMappings.Mapping
    let mappings = ProductDemandProjections.mappings
  }

  module ProductDemandReadModelMaker = Platform.ReadModel.Make(
    ProductDemandReadModel,
    ProductDemandMappings,
  )

  // Compile the Products extension point mapping, then build the EP component
  module ProductsEPMappingT = ExtensionPointMapping.Make(
    ProductsExtensionPointSpec,
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = ProductsExtensionPointSpec
    module type Mapping = ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    ProductsExtensionPointSpec,
    ProductsEPMappings,
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrdersExtensionPointSpec,
    OrdersExtension.Mappings,
  )

  // extensionPoints = [module(ProductsExtensionPointMaker)]
  // extensions     = [module(OrdersExtensionMaker)]
}
