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
    ReventlessInfra.NoEventMappings.Make(ProductDemand),
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
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    ProductsExtensionPointSpec,
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = ProductsExtensionPointSpec
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
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

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  let make = (
    ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
    ~api: Platform.api,
    ~apiRole: Platform.role,
  ) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~version="1.0.0",
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
      ~api,
      ~apiRole,
      ~scheduler,
    )
}
