// AUTO-GENERATED — do not edit. Run `npm run generate` to update.
open Reventless.Projection

module Make = (
  Platform: ReventlessInfra.Platform.T
    with type api = ReventlessAws.Types.AppSync.api
    and type role = ReventlessAws.Types.AppSync.role,
) => {
  open CatalogPlugin

  // StateChangeSlices
  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct, AddProduct_Behavior)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription, ChangeProductDescription_Behavior)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName, ChangeProductName_Behavior)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice, ChangeProductPrice_Behavior)
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand, RecordProductDemand_Behavior)

  // StateViewSliceStreams
  module ProductDemandViewStreamSlice = Platform.StateViewSliceStream.Make(ProductDemandView, ProductDemandView_Projection)
  module ProductsViewStreamSlice = Platform.StateViewSliceStream.Make(ProductsView, ProductsView_Projection)

  // InboundTranslationSlices
  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct, ImportProduct_Translation)

  // Aggregates
  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    ReventlessInfra.NoEventMappings.Make(Category),
  )

  // ReadModels
  @reventless.projections
  module CatalogActivityProjectionsWrapper: Mappings with module Target := CatalogActivityReadModel = {
    let mappings: array<module(Mapping)> = [module(CatalogActivityProjections.CategoryActivityMapping), module(CatalogActivityProjections.ProductActivityMapping)]
  }
  module CatalogActivityReadModel = Platform.ReadModel.Make(CatalogActivityReadModel, CatalogActivityProjectionsWrapper)
  @reventless.projections
  module CategoriesProjectionsWrapper: Mappings with module Target := CategoriesReadModel = {
    let mappings: array<module(Mapping)> = [module(CategoriesProjections.CategoryMapping)]
  }
  module CategoriesReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoriesProjectionsWrapper)

  // Tasks
  module ImportProductsTask = Platform.Task.Make(ImportProducts)

  // ExtensionPoints
  module ProductsExtensionPoint = Platform.ExtensionPoint.Make(ProductsExtensionPointMapping)

  // Extensions
  module OrdersExtension = Platform.Extension.Make(OrdersExtension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Catalog",
    ~aggregates=[module(CategoryAggregate)],
    ~readModels=[module(CatalogActivityReadModel), module(CategoriesReadModel)],
    ~stateViewSlices=[module(ProductDemandViewStreamSlice), module(ProductsViewStreamSlice)],
    ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
    ~inboundTranslationSlices=[module(ImportProductSlice)],
    ~extensions=[module(OrdersExtension)],
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPoint)],
      ~extensions=[module(OrdersExtension)],
      ~aggregates=[module(CategoryAggregate)],
      ~readModels=[module(CatalogActivityReadModel), module(CategoriesReadModel)],
      ~tasks=[module(ImportProductsTask)],
      ~stateChangeSlices=[module(AddProductSlice), module(ChangeProductDescriptionSlice), module(ChangeProductNameSlice), module(ChangeProductPriceSlice), module(RecordProductDemandSlice)],
      ~stateViewSlices=[module(ProductDemandViewStreamSlice), module(ProductsViewStreamSlice)],
      ~inboundTranslationSlices=[module(ImportProductSlice)],
      ~pluginStructure=pluginStructure,
    )
}
