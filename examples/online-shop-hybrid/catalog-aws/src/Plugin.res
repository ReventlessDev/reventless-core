// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  // StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(CatalogPlugin.AddProduct)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(CatalogPlugin.ChangeProductDescription)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(CatalogPlugin.ChangeProductName)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(CatalogPlugin.ChangeProductPrice)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(CatalogPlugin.RecordProductDemand)

  // StateViewSliceStreams
  module ProductDemandViewStreamSlice = Platform.StateViewSliceStream.Make(CatalogPlugin.ProductDemandView)
  module ProductsViewStreamSlice = Platform.StateViewSliceStream.Make(CatalogPlugin.ProductsView)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(CatalogPlugin.ImportProduct)

  // Aggregates
  module CategoryAggregate = ReventlessAws.Aggregate_Builder_Single.Make(
    CatalogPlugin.Category,
    CatalogPlugin.CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(CatalogPlugin.Category),
  )

  // ReadModels
  @reventless.projections
  module CategoriesProjectionsWrapper: Mappings with module Target := CatalogPlugin.CategoriesReadModel = {
    let mappings: array<module(Mapping)> = [module(CatalogPlugin.CategoriesProjections.CategoryMapping)]
  }
  module CategoriesReadModelMaker = ReventlessAws.ReadModel_Builder_Single.Make(
    CatalogPlugin.CategoriesReadModel,
    CategoriesProjectionsWrapper,
  )

  // Tasks
  module ImportProductsTask = Platform.Task.Make(CatalogPlugin.ImportProducts)

  // ExtensionPoints
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogPlugin.ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = CatalogPlugin.ProductsExtensionPointMapping.ExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let name = "ProductsEPMappings"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = ReventlessAws.ExtensionPoint_Builder.Make(
    ProductsEPMappings.Spec,
    ProductsEPMappings,
    {
      let publishToAggregatesQueueUrls = Dict.make()
    },
  )

  // Extensions
  module OrdersExtensionMaker = Platform.Extension.Make(CatalogPlugin.OrdersExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate)],
    ~readModels=[module(CategoriesReadModelMaker)],
    ~stateViewSlices=[module(ProductDemandViewStreamSlice), module(ProductsViewStreamSlice)],
    ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(OrdersExtensionMaker)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CategoriesReadModelMaker)],
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
      ~stateViewSlices=[module(ProductDemandViewStreamSlice), module(ProductsViewStreamSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~pluginStructure=pluginStructure,
    )
}
